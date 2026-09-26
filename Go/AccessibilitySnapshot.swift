//
//  AccessibilitySnapshot.swift
//  Go
//
//  Reads an app's accessibility tree (what macOS publishes for VoiceOver) so
//  Go can find named controls instead of guessing pixels.
//

import AppKit
import ApplicationServices

/// One element in an app's accessibility tree, with its frame in AppKit coordinates.
nonisolated struct AccessibilityElementNode {
    let role: String
    let subrole: String?

    /// App-written text, so it arrives labelled as untrusted.
    let title: UntrustedText?
    let value: UntrustedText?

    let radioSelection: Bool?

    /// Many controls have no title and publish their label here.
    let elementDescription: UntrustedText?

    let frameInAppKitCoordinates: CGRect
    let depth: Int
    let children: [AccessibilityElementNode]

    /// Actions the element publishes; empty means AX cannot act on it.
    let publishedActionNames: [String]

    /// The human-readable name, wherever the app published it (title,
    /// description or value).
    var displayName: UntrustedText? { title ?? elementDescription ?? value }

    /// Named, publishes an action, and has a non-zero frame.
    var isActionable: Bool {
        displayName != nil
            && !publishedActionNames.isEmpty
            && frameInAppKitCoordinates.width > 0
            && frameInAppKitCoordinates.height > 0
    }

    /// True when the subrole could not be read. A failed read must not look like
    /// "not a password field".
    let subroleReadFailed: Bool

    /// The live element; nil on nodes built by tests.
    let accessibilityElement: AXUIElement?

    init(
        role: String,
        subrole: String?,
        title: String?,
        value: String?,
        elementDescription: String? = nil,
        frameInAppKitCoordinates: CGRect,
        depth: Int,
        children: [AccessibilityElementNode],
        publishedActionNames: [String] = [],
        subroleReadFailed: Bool = false,
        accessibilityElement: AXUIElement? = nil,
        radioSelection: Bool? = nil
    ) {
        self.role = role
        self.subrole = subrole
        self.title = title.map(UntrustedText.init)
        self.value = value.map(UntrustedText.init)
        self.radioSelection = role == kAXRadioButtonRole ? radioSelection : nil
        self.elementDescription = elementDescription.map(UntrustedText.init)
        self.frameInAppKitCoordinates = frameInAppKitCoordinates
        self.depth = depth
        self.children = children
        self.publishedActionNames = publishedActionNames
        self.subroleReadFailed = subroleReadFailed
        self.accessibilityElement = accessibilityElement
    }
}

/// An `AXUIElement` usable in a `Set` (CF equality and hashing). Chrome
/// publishes some elements under several parents.
nonisolated struct AccessibilityElementKey: Hashable {
    let element: AXUIElement

    static func == (lhs: AccessibilityElementKey, rhs: AccessibilityElementKey) -> Bool {
        CFEqual(lhs.element, rhs.element)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(CFHash(element))
    }
}

/// Why a walk stopped early.
nonisolated enum WalkStopReason: String, CaseIterable {
    case depthLimit = "hit the depth limit"
    case nodeLimit = "hit the node limit"
    case timeLimit = "ran out of time"
}

nonisolated struct AccessibilityWalkBudget {
    let maximumDepth: Int
    let maximumNodeCount: Int

    /// Wall-clock limit for a walk against a slow app. Five seconds is well above
    /// the slowest normal walk (Mail, about 1.8 s).
    let deadline: Date

    private(set) var nodesVisited = 0
    private(set) var stopReasons: Set<WalkStopReason> = []

    /// Prefer reporting `stopReasons`, which say why.
    var wasTruncated: Bool { !stopReasons.isEmpty }

    init(maximumDepth: Int, maximumNodeCount: Int, timeLimitInSeconds: Double = 5.0) {
        self.maximumDepth = maximumDepth
        self.maximumNodeCount = maximumNodeCount
        self.deadline = Date().addingTimeInterval(timeLimitInSeconds)
    }

    /// Spends one slot if a node at this depth may be visited, otherwise records
    /// which limit stopped the walk.
    mutating func claimSlot(atDepth depth: Int) -> Bool {
        guard depth < maximumDepth else {
            stopReasons.insert(.depthLimit)
            return false
        }
        guard nodesVisited < maximumNodeCount else {
            stopReasons.insert(.nodeLimit)
            return false
        }
        // Checked per node, since one slow read can blow the budget.
        guard Date() < deadline else {
            stopReasons.insert(.timeLimit)
            return false
        }

        nodesVisited += 1
        return true
    }
}

/// The result of one walk and what it cost.
nonisolated struct AccessibilityWindowSnapshot {
    let rootNode: AccessibilityElementNode?
    let applicationName: String
    let bundleIdentifier: String
    let walkDurationInSeconds: Double
    let nodeCount: Int
    let deepestLevelReached: Int
    let wasTruncatedByBudget: Bool

    /// Which limits stopped the walk; empty means it finished.
    let walkStopReasons: Set<WalkStopReason>
    let timedOutNodePaths: [String]
    let nodesWithoutReadableFrame: Int
    let subtreesLostToFailedReads: Int

    /// Subtrees skipped because they sit far outside the window (reported, not hidden).
    let subtreesSkippedFarOffScreen: Int
    let nodesSkippedFarOffScreen: Int

    /// Containers where only the visible children (plus a margin) were walked,
    /// like a long message list.
    let containersReducedToVisibleChildren: Int
    let childrenElidedByVisibleSubset: Int

    /// Elements skipped because they were already walked under another parent.
    let duplicateElementsSkipped: Int

    /// True when the frontmost app changed during the walk.
    let focusChangedDuringWalk: Bool

    /// Which source named the frontmost app; nil when the caller named the window.
    var frontmostSource: AccessibilityTreeWalker.FrontmostSource? = nil

    /// The process that was walked; a capture after a failed resolution uses this app.
    var application: NSRunningApplication? = nil
}

nonisolated enum AccessibilitySnapshotError: Error {
    case accessibilityPermissionNotGranted
    case noFrontmostApplication
    case noFocusedWindow

    /// The screen is locked, so there is nothing of the user's to read.
    case screenIsLocked
}

/// Bundle ids that mean the lock screen is in front. Reads return a plausible
/// 1-node tree there, so they are refused.
nonisolated enum LockScreenGuard {
    static let bundleIdentifiers: Set<String> = ["com.apple.loginwindow", "com.apple.ScreenSaver.Engine"]

    static func isLockScreen(_ bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier else { return false }
        return bundleIdentifiers.contains(bundleIdentifier)
    }
}

nonisolated enum AccessibilityTreeWalker {

    /// Asks an Electron app to build its accessibility tree (`AXManualAccessibility`).
    /// Set without probing: the attribute is hidden from attribute lists. Native
    /// apps answer "unsupported", which is fine.
    @discardableResult
    static func requestManualAccessibility(from applicationElement: AXUIElement) -> AXError {
        AXUIElementSetAttributeValue(
            applicationElement,
            "AXManualAccessibility" as CFString,
            kCFBooleanTrue
        )
    }

    static func convertAccessibilityFrameToAppKitFrame(
        _ accessibilityFrame: CGRect,
        primaryDisplayHeightInPoints: CGFloat
    ) -> CGRect {
        let appKitOriginY = primaryDisplayHeightInPoints
            - accessibilityFrame.origin.y
            - accessibilityFrame.height

        return CGRect(
            x: accessibilityFrame.origin.x,
            y: appKitOriginY,
            width: accessibilityFrame.width,
            height: accessibilityFrame.height
        )
    }

    private static func appendSerializedLines(
        for node: AccessibilityElementNode,
        into lines: inout [String]
    ) {
        let indentation = String(repeating: "  ", count: node.depth)
        // All fragments are app-written, so each is escaped and capped.
        let titleFragment = node.title.map { " " + $0.forDisplay } ?? ""
        let descriptionFragment = node.elementDescription.map { " desc=" + $0.forDisplay } ?? ""
        let valueFragment = node.value.map { " = " + $0.forDisplay } ?? ""
        let frameFragment = String(
            format: "(%.0f, %.0f, %.0f, %.0f)",
            node.frameInAppKitCoordinates.origin.x,
            node.frameInAppKitCoordinates.origin.y,
            node.frameInAppKitCoordinates.width,
            node.frameInAppKitCoordinates.height
        )

        let actionsFragment = node.publishedActionNames.isEmpty
            ? ""
            : " [" + node.publishedActionNames.joined(separator: ",") + "]"

        lines.append(indentation + node.role + titleFragment + descriptionFragment + valueFragment + " " + frameFragment + actionsFragment)

        for childNode in node.children {
            appendSerializedLines(for: childNode, into: &lines)
        }
    }

    /// The focused app, asked of Accessibility (live) rather than `NSWorkspace`
    /// (a cache that can lag). Falls back to the cache when AX cannot answer,
    /// which is common for Electron apps until their tree is switched on.
    static func focusedApplication() -> NSRunningApplication? {
        frontmost().application
    }

    /// Which source named the frontmost application.
    enum FrontmostSource: String {
        /// Live system-wide AX read.
        case accessibility
        /// The `NSWorkspace` cache, confirmed by the app's own `kAXFrontmostAttribute`.
        case cacheConfirmedByApp
        /// The `NSWorkspace` cache, unconfirmed.
        case cacheUnconfirmed
    }

    struct FrontmostRead {
        let application: NSRunningApplication?
        let source: FrontmostSource
        /// The system-wide read's raw error; nil when it answered.
        let systemWideErrorRawValue: Int32?
    }

    static func frontmostSource(
        systemWideAnswered: Bool,
        cachedApplicationSaysFrontmost: Bool?
    ) -> FrontmostSource {
        if systemWideAnswered { return .accessibility }
        return cachedApplicationSaysFrontmost == true ? .cacheConfirmedByApp : .cacheUnconfirmed
    }

    /// `focusedApplication()` plus which source answered.
    static func frontmost() -> FrontmostRead {
        var value: AnyObject?
        let systemWideError = AXUIElementCopyAttributeValue(
            AXUIElementCreateSystemWide(), kAXFocusedApplicationAttribute as CFString, &value
        )
        if systemWideError == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID() {
            var processIdentifier: pid_t = 0
            if AXUIElementGetPid(value as! AXUIElement, &processIdentifier) == .success,
               let application = NSRunningApplication(processIdentifier: processIdentifier) {
                return FrontmostRead(application: application, source: .accessibility, systemWideErrorRawValue: nil)
            }
        }

        let cached = NSWorkspace.shared.frontmostApplication
        var cachedApplicationSaysFrontmost: Bool?
        if let cached {
            let element = AXUIElementCreateApplication(cached.processIdentifier)
            AXUIElementSetMessagingTimeout(element, 0.5)
            var frontmostValue: AnyObject?
            if AXUIElementCopyAttributeValue(element, kAXFrontmostAttribute as CFString, &frontmostValue) == .success {
                cachedApplicationSaysFrontmost = frontmostValue as? Bool
            }
        }
        return FrontmostRead(
            application: cached,
            source: frontmostSource(
                systemWideAnswered: false, cachedApplicationSaysFrontmost: cachedApplicationSaysFrontmost
            ),
            systemWideErrorRawValue: systemWideError == .success ? nil : systemWideError.rawValue
        )
    }

    /// Walks the focused window of the frontmost app. Every read is synchronous
    /// IPC, so a messaging timeout bounds each one.
    static func snapshotFocusedWindow(
        maximumDepth: Int = 120,
        maximumNodeCount: Int = 25_000
    ) throws -> AccessibilityWindowSnapshot {
        try snapshotFocusedWindow(focusedWindowTarget(), maximumDepth: maximumDepth, maximumNodeCount: maximumNodeCount)
    }

    typealias FocusedWindowTarget = (window: AXUIElement, application: NSRunningApplication, frontmostSource: FrontmostSource)

    /// The pre-walk steps of `snapshotFocusedWindow`, split out so `menu` can
    /// count windows before the walk.
    static func focusedWindowTarget() throws -> FocusedWindowTarget {
        guard AXIsProcessTrusted() else {
            throw AccessibilitySnapshotError.accessibilityPermissionNotGranted
        }

        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.5)

        let frontmostRead = frontmost()
        guard let frontmostApplication = frontmostRead.application else {
            throw AccessibilitySnapshotError.noFrontmostApplication
        }

        // Refuse rather than describe the lock screen.
        guard !LockScreenGuard.isLockScreen(frontmostApplication.bundleIdentifier) else {
            throw AccessibilitySnapshotError.screenIsLocked
        }

        // Set on the system-wide element: a timeout on one element covers only that
        // element, and every child read is a fresh object.
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.5)

        let applicationElement = AXUIElementCreateApplication(frontmostApplication.processIdentifier)
        // Native apps answer "unsupported"; only an app that accepts needs time to
        // build its tree.
        let manualAccessibilityResult = requestManualAccessibility(from: applicationElement)
        let wasGatedApp = manualAccessibilityResult == .success

        // A gated app builds its tree after accepting and doesn't say when it's done,
        // so retry until the window appears.
        var focusedWindowElement = copyElementAttribute(
            from: applicationElement,
            attribute: kAXFocusedWindowAttribute
        )
        if wasGatedApp {
            var attemptsRemaining = 20   // 20 x 100 ms = 2 s ceiling
            while focusedWindowElement == nil, attemptsRemaining > 0 {
                Thread.sleep(forTimeInterval: 0.1)
                focusedWindowElement = copyElementAttribute(
                    from: applicationElement,
                    attribute: kAXFocusedWindowAttribute
                )
                attemptsRemaining -= 1
            }
            print("🔓 AXManualAccessibility accepted by \(frontmostApplication.localizedName ?? "?") — window after \((20 - attemptsRemaining) * 100) ms")
        } else {
            print("🔒 not gated (AXError \(manualAccessibilityResult.rawValue)) — native app, tree was always there")
        }

        // `AXFocusedWindow` is not universal; try the other window attributes first.
        if focusedWindowElement == nil {
            focusedWindowElement = copyElementAttribute(
                from: applicationElement,
                attribute: kAXMainWindowAttribute
            )
            if focusedWindowElement != nil { print("   ↳ no AXFocusedWindow; used AXMainWindow") }
        }
        if focusedWindowElement == nil {
            var windowsValue: CFTypeRef?
            if AXUIElementCopyAttributeValue(
                applicationElement, kAXWindowsAttribute as CFString, &windowsValue
            ) == .success,
               let windows = windowsValue as? [AXUIElement], let first = windows.first {
                focusedWindowElement = first
                print("   ↳ no AXFocusedWindow/AXMainWindow; used AXWindows[0] of \(windows.count)")
            }
        }
        if focusedWindowElement == nil {
            var names: CFArray?
            AXUIElementCopyAttributeNames(applicationElement, &names)
            print("   ↳ application element publishes: \((names as? [String] ?? []).joined(separator: ", "))")
        }

        guard let focusedWindowElement else {
            throw AccessibilitySnapshotError.noFocusedWindow
        }
        return (focusedWindowElement, frontmostApplication, frontmostRead.source)
    }

    static func snapshotFocusedWindow(
        _ target: FocusedWindowTarget,
        maximumDepth: Int = 120,
        maximumNodeCount: Int = 25_000
    ) throws -> AccessibilityWindowSnapshot {
        var snapshot = try snapshotWindow(
            target.window,
            of: target.application,
            maximumDepth: maximumDepth,
            maximumNodeCount: maximumNodeCount
        )
        snapshot.frontmostSource = target.frontmostSource
        return snapshot
    }

    /// Walks one window of one app. The only walk implementation, so every verb
    /// and the pre-capture check read the same tree.
    static func snapshotWindow(
        _ windowElement: AXUIElement,
        of application: NSRunningApplication,
        maximumDepth: Int = 120,
        maximumNodeCount: Int = 25_000
    ) throws -> AccessibilityWindowSnapshot {
        guard AXIsProcessTrusted() else {
            throw AccessibilitySnapshotError.accessibilityPermissionNotGranted
        }
        guard !LockScreenGuard.isLockScreen(application.bundleIdentifier) else {
            throw AccessibilitySnapshotError.screenIsLocked
        }
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.5)

        // The main display defines AX's origin. CG, not NSScreen: this runs off main.
        let primaryDisplayHeightInPoints = CGDisplayBounds(CGMainDisplayID()).height
        let frontmostAtStart = AccessibilityTreeWalker.focusedApplication()?.processIdentifier

        var budget = AccessibilityWalkBudget(
            maximumDepth: maximumDepth,
            maximumNodeCount: maximumNodeCount
        )
        var deepestLevelReached = 0
        var timedOutNodePaths: [String] = []
        var nodesWithoutReadableFrame = 0
        var subtreesLostToFailedReads = 0
        var subtreesSkippedFarOffScreen = 0
        var nodesSkippedFarOffScreen = 0
        var containersReducedToVisibleChildren = 0
        var childrenElidedByVisibleSubset = 0
        var duplicateElementsSkipped = 0
        var visitedElements: Set<AccessibilityElementKey> = [
            AccessibilityElementKey(element: windowElement)
        ]

        // Subtrees more than one window-height outside the window are skipped; things
        // a scroll or two away stay in the tree.
        var windowFrameValue: CFTypeRef?
        AXUIElementCopyAttributeValue(windowElement, "AXFrame" as CFString, &windowFrameValue)
        var windowRect = CGRect.zero
        if let windowFrameValue, CFGetTypeID(windowFrameValue) == AXValueGetTypeID() {
            AXValueGetValue(windowFrameValue as! AXValue, .cgRect, &windowRect)
        }
        let reachableArea: CGRect? = windowRect.isEmpty
            ? nil
            : convertAccessibilityFrameToAppKitFrame(
                windowRect, primaryDisplayHeightInPoints: primaryDisplayHeightInPoints
              ).insetBy(dx: -windowRect.width, dy: -windowRect.height)

        let walkStartedAt = Date()
        let rootNode = buildNode(
            from: windowElement,
            depth: 0,
            primaryDisplayHeightInPoints: primaryDisplayHeightInPoints,
            budget: &budget,
            deepestLevelReached: &deepestLevelReached,
            timedOutNodePaths: &timedOutNodePaths,
            nodesWithoutReadableFrame: &nodesWithoutReadableFrame,
            subtreesLostToFailedReads: &subtreesLostToFailedReads,
            reachableArea: reachableArea,
            subtreesSkippedFarOffScreen: &subtreesSkippedFarOffScreen,
            nodesSkippedFarOffScreen: &nodesSkippedFarOffScreen,
            containersReducedToVisibleChildren: &containersReducedToVisibleChildren,
            childrenElidedByVisibleSubset: &childrenElidedByVisibleSubset,
            visitedElements: &visitedElements,
            duplicateElementsSkipped: &duplicateElementsSkipped
        )
        let walkDurationInSeconds = Date().timeIntervalSince(walkStartedAt)

        // Compared with the frontmost app at the start of the walk.
        let focusChangedDuringWalk =
            AccessibilityTreeWalker.focusedApplication()?.processIdentifier != frontmostAtStart

        return AccessibilityWindowSnapshot(
            rootNode: rootNode,
            applicationName: application.localizedName ?? "unknown",
            bundleIdentifier: application.bundleIdentifier ?? "unknown",
            walkDurationInSeconds: walkDurationInSeconds,
            nodeCount: budget.nodesVisited,
            deepestLevelReached: deepestLevelReached,
            wasTruncatedByBudget: budget.wasTruncated,
            walkStopReasons: budget.stopReasons,
            timedOutNodePaths: timedOutNodePaths,
            nodesWithoutReadableFrame: nodesWithoutReadableFrame,
            subtreesLostToFailedReads: subtreesLostToFailedReads,
            subtreesSkippedFarOffScreen: subtreesSkippedFarOffScreen,
            nodesSkippedFarOffScreen: nodesSkippedFarOffScreen,
            containersReducedToVisibleChildren: containersReducedToVisibleChildren,
            childrenElidedByVisibleSubset: childrenElidedByVisibleSubset,
            duplicateElementsSkipped: duplicateElementsSkipped,
            focusChangedDuringWalk: focusChangedDuringWalk,
            application: application
        )
    }

    // MARK: - Batched reads

    /// The attributes every node needs, read in one call. `AXActionNames` is a
    /// separate API and is read on its own.
    private static let batchedAttributeNames: [String] = [
        kAXRoleAttribute, kAXSubroleAttribute, kAXTitleAttribute,
        kAXValueAttribute, kAXDescriptionAttribute, "AXFrame", kAXChildrenAttribute
    ]

    static func decodeRadioSelection(_ rawValue: AnyObject?) -> Bool? {
        guard let number = rawValue as? NSNumber else { return nil }
        if number == NSNumber(value: 0) { return false }
        if number == NSNumber(value: 1) { return true }
        return nil
    }

    private struct BatchedNodeRead {
        var role: String?
        var subrole: String?
        var title: String?
        var value: String?
        var numericValue: NSNumber?
        var elementDescription: String?
        var frame: CGRect?
        var children: [AXUIElement] = []
        var childReadFailed = false
        var frameDidTimeOut = false
    }

    /// Returns nil only when the batch call itself failed. Failed entries come
    /// back as AXValue-wrapped errors, so "no children" and "read failed" differ.
    private static func batchedRead(from element: AXUIElement) -> BatchedNodeRead? {
        var rawValues: CFArray?
        let result = AXUIElementCopyMultipleAttributeValues(
            element,
            batchedAttributeNames as CFArray,
            AXCopyMultipleAttributeOptions(),   // never .stopOnError: one bad attribute must not lose the rest
            &rawValues
        )
        guard result == .success,
              let values = rawValues as? [AnyObject],
              values.count == batchedAttributeNames.count else {
            return nil
        }

        func errorCode(at index: Int) -> AXError? {
            let entry = values[index]
            guard CFGetTypeID(entry) == AXValueGetTypeID() else { return nil }
            let axValue = entry as! AXValue
            guard AXValueGetType(axValue) == .axError else { return nil }
            var code = AXError.success
            guard AXValueGetValue(axValue, .axError, &code) else { return nil }
            return code
        }

        func string(at index: Int) -> String? {
            guard errorCode(at: index) == nil,
                  let text = values[index] as? String, !text.isEmpty else { return nil }
            return text
        }

        var read = BatchedNodeRead()
        read.role = string(at: 0)
        read.subrole = string(at: 1)
        read.title = string(at: 2)
        read.value = string(at: 3)
        read.numericValue = values[3] as? NSNumber
        read.elementDescription = string(at: 4)

        if errorCode(at: 5) == nil, CFGetTypeID(values[5]) == AXValueGetTypeID() {
            let axValue = values[5] as! AXValue
            var rect = CGRect.zero
            if AXValueGetType(axValue) == .cgRect, AXValueGetValue(axValue, .cgRect, &rect) {
                read.frame = rect
            }
        } else if errorCode(at: 5) == .cannotComplete {
            read.frameDidTimeOut = true
        }

        if let childError = errorCode(at: 6) {
            // These two errors mean genuinely empty.
            read.childReadFailed = !(childError == .noValue || childError == .attributeUnsupported)
        } else if let kids = values[6] as? [AXUIElement] {
            read.children = kids
        }

        return read
    }

    private static func buildNode(
        from element: AXUIElement,
        depth: Int,
        primaryDisplayHeightInPoints: CGFloat,
        budget: inout AccessibilityWalkBudget,
        deepestLevelReached: inout Int,
        timedOutNodePaths: inout [String],
        nodesWithoutReadableFrame: inout Int,
        subtreesLostToFailedReads: inout Int,
        reachableArea: CGRect?,
        subtreesSkippedFarOffScreen: inout Int,
        nodesSkippedFarOffScreen: inout Int,
        containersReducedToVisibleChildren: inout Int,
        childrenElidedByVisibleSubset: inout Int,
        visitedElements: inout Set<AccessibilityElementKey>,
        duplicateElementsSkipped: inout Int
    ) -> AccessibilityElementNode? {
        guard budget.claimSlot(atDepth: depth) else { return nil }

        deepestLevelReached = max(deepestLevelReached, depth)

        // Individual reads remain as the fallback for apps that refuse batching.
        let batched = batchedRead(from: element)

        let role = batched?.role
            ?? copyStringAttribute(from: element, attribute: kAXRoleAttribute)
            ?? "AXUnknown"
        // Keep "could not read" distinct from "no subrole" (password field check).
        var subrole = batched?.subrole
        var subroleReadFailed = false
        if subrole == nil {
            var rawSubrole: AnyObject?
            let subroleError = AXUIElementCopyAttributeValue(
                element, kAXSubroleAttribute as CFString, &rawSubrole
            )
            if subroleError == .success {
                subrole = (rawSubrole as? String).flatMap { $0.isEmpty ? nil : $0 }
            } else {
                subroleReadFailed = !(subroleError == .noValue || subroleError == .attributeUnsupported)
            }
        }
        let title = batched?.title ?? copyStringAttribute(from: element, attribute: kAXTitleAttribute)
        let value = batched?.value ?? copyStringAttribute(from: element, attribute: kAXValueAttribute)
        var radioSelection: Bool?
        if role == kAXRadioButtonRole {
            if let batched {
                radioSelection = decodeRadioSelection(batched.numericValue)
            } else {
                var rawValue: AnyObject?
                if AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &rawValue) == .success {
                    radioSelection = decodeRadioSelection(rawValue)
                }
            }
        }
        let elementDescription = batched?.elementDescription
            ?? copyStringAttribute(from: element, attribute: kAXDescriptionAttribute)

        // `AXFrame` is not universal; fall back to position and size.
        let frameReadResult: (frame: CGRect?, didTimeOut: Bool)
        if let batched, batched.frame != nil {
            frameReadResult = (batched.frame, false)
        } else if let batched, batched.frameDidTimeOut {
            frameReadResult = (nil, true)
        } else {
            frameReadResult = copyFrame(from: element)
        }

        if frameReadResult.didTimeOut {
            timedOutNodePaths.append("\(role) at depth \(depth)")
        } else if frameReadResult.frame == nil {
            nodesWithoutReadableFrame += 1
        }

        let appKitFrame = convertAccessibilityFrameToAppKitFrame(
            frameReadResult.frame ?? .zero,
            primaryDisplayHeightInPoints: primaryDisplayHeightInPoints
        )

        var childNodes: [AccessibilityElementNode] = []
        let childReadResult = batched.map { (children: $0.children, readFailed: $0.childReadFailed) }
            ?? copyChildElements(from: element)
        if childReadResult.readFailed {
            subtreesLostToFailedReads += 1
        }

        // Stop descending far outside the window. A zero-area frame is not "outside".
        let isFarOffScreen: Bool = {
            guard let reachableArea, depth > 0,
                  appKitFrame.width > 0, appKitFrame.height > 0 else { return false }
            return !appKitFrame.intersects(reachableArea)
        }()

        if isFarOffScreen, !childReadResult.children.isEmpty {
            subtreesSkippedFarOffScreen += 1
            nodesSkippedFarOffScreen += childReadResult.children.count
        }

        // Ask the container which children are visible instead of reading them all.
        var childrenToWalk = isFarOffScreen ? [] : childReadResult.children
        if !isFarOffScreen,
           let window = visibleChildWindow(of: element, children: childReadResult.children) {
            containersReducedToVisibleChildren += 1
            childrenElidedByVisibleSubset += childReadResult.children.count - window.count
            childrenToWalk = Array(childReadResult.children[window])
        }

        // Each element once. Filtered here so a duplicate doesn't end the sibling loop.
        let beforeDeduplication = childrenToWalk.count
        childrenToWalk = childrenToWalk.filter {
            visitedElements.insert(AccessibilityElementKey(element: $0)).inserted
        }
        duplicateElementsSkipped += beforeDeduplication - childrenToWalk.count

        for childElement in childrenToWalk {
            guard let childNode = buildNode(
                from: childElement,
                depth: depth + 1,
                primaryDisplayHeightInPoints: primaryDisplayHeightInPoints,
                budget: &budget,
                deepestLevelReached: &deepestLevelReached,
                timedOutNodePaths: &timedOutNodePaths,
                nodesWithoutReadableFrame: &nodesWithoutReadableFrame,
                subtreesLostToFailedReads: &subtreesLostToFailedReads,
                reachableArea: reachableArea,
                subtreesSkippedFarOffScreen: &subtreesSkippedFarOffScreen,
                nodesSkippedFarOffScreen: &nodesSkippedFarOffScreen,
                containersReducedToVisibleChildren: &containersReducedToVisibleChildren,
                childrenElidedByVisibleSubset: &childrenElidedByVisibleSubset,
                visitedElements: &visitedElements,
                duplicateElementsSkipped: &duplicateElementsSkipped
            ) else { break }

            childNodes.append(childNode)
        }

        // Skip the (expensive) action read for nodes that can never be actionable.
        let couldEverBeActionable = (title ?? elementDescription ?? value) != nil
            && appKitFrame.width > 0 && appKitFrame.height > 0
        let publishedActionNames = couldEverBeActionable
            ? copyActionNames(from: element)
            : []

        return AccessibilityElementNode(
            role: role,
            subrole: subrole,
            title: title,
            value: value,
            elementDescription: elementDescription,
            frameInAppKitCoordinates: appKitFrame,
            depth: depth,
            children: childNodes,
            publishedActionNames: publishedActionNames,
            subroleReadFailed: subroleReadFailed,
            accessibilityElement: element,
            radioSelection: radioSelection
        )
    }

    /// For containers that know which children are visible (like a long list),
    /// walk the visible run plus one screenful either side. nil to walk them all.
    static let visibleChildAttributes = ["AXVisibleRows", "AXVisibleChildren", "AXVisibleCells"]
    static let minimumChildrenToAskForVisibleSubset = 50

    static func visibleChildWindow(
        of element: AXUIElement,
        children: [AXUIElement]
    ) -> Range<Int>? {
        guard children.count >= minimumChildrenToAskForVisibleSubset else { return nil }

        var visible: [AXUIElement] = []
        for attribute in visibleChildAttributes {
            var out: AnyObject?
            guard AXUIElementCopyAttributeValue(element, attribute as CFString, &out) == .success,
                  let elements = out as? [AXUIElement], !elements.isEmpty else { continue }
            visible = elements
            break
        }
        guard !visible.isEmpty, visible.count < children.count else { return nil }

        var firstVisible: Int?
        var lastVisible: Int?
        for (index, child) in children.enumerated()
        where visible.contains(where: { CFEqual($0, child) }) {
            if firstVisible == nil { firstVisible = index }
            lastVisible = index
        }

        // Visible children missing from the list: walk everything instead.
        guard let firstVisible, let lastVisible else { return nil }

        return visibleWindowRange(
            firstVisible: firstVisible,
            lastVisible: lastVisible,
            visibleCount: visible.count,
            childCount: children.count
        )
    }

    /// The index arithmetic, testable on its own.
    static func visibleWindowRange(
        firstVisible: Int,
        lastVisible: Int,
        visibleCount: Int,
        childCount: Int
    ) -> Range<Int>? {
        let margin = visibleCount
        let lower = max(0, firstVisible - margin)
        let upper = min(childCount, lastVisible + 1 + margin)
        guard upper > lower, upper - lower < childCount else { return nil }
        return lower..<upper
    }

    /// The actions an element publishes; roles alone don't say what it can do.
    static func copyActionNames(from element: AXUIElement) -> [String] {
        var actionNamesValue: CFArray?
        guard AXUIElementCopyActionNames(element, &actionNamesValue) == .success,
              let actionNames = actionNamesValue as? [String] else {
            return []
        }
        return actionNames
    }

    private static func copyStringAttribute(from element: AXUIElement, attribute: String) -> String? {
        var attributeValue: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &attributeValue) == .success,
              let stringValue = attributeValue as? String,
              !stringValue.isEmpty else {
            return nil
        }
        return stringValue
    }

    private static func copyElementAttribute(from element: AXUIElement, attribute: String) -> AXUIElement? {
        var attributeValue: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &attributeValue) == .success,
              let attributeValue,
              CFGetTypeID(attributeValue) == AXUIElementGetTypeID() else {
            return nil
        }
        return (attributeValue as! AXUIElement)
    }

    /// Reads children and reports whether the read failed, so a stalled app is
    /// not mistaken for an empty one.
    private static func copyChildElements(
        from element: AXUIElement
    ) -> (children: [AXUIElement], readFailed: Bool) {
        var attributeValue: AnyObject?
        let result = AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &attributeValue)

        if result == .noValue || result == .attributeUnsupported {
            return ([], false)
        }
        guard result == .success, let childElements = attributeValue as? [AXUIElement] else {
            return ([], true)
        }
        return (childElements, false)
    }

    /// Reads a frame and says whether a failure was a timeout.
    static func copyFrame(from element: AXUIElement) -> (frame: CGRect?, didTimeOut: Bool) {
        var positionValue: AnyObject?
        var sizeValue: AnyObject?

        let positionResult = AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue)
        let sizeResult = AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue)
        let didTimeOut = positionResult == .cannotComplete || sizeResult == .cannotComplete

        guard positionResult == .success,
              sizeResult == .success,
              let positionValue,
              let sizeValue,
              CFGetTypeID(positionValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID() else {
            return (nil, didTimeOut)
        }

        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &position),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else {
            return (nil, didTimeOut)
        }

        return (CGRect(origin: position, size: size), false)
    }
}

nonisolated extension AccessibilityElementNode {
    /// Every node in this subtree, including this one.
    func flattenedDescendants() -> [AccessibilityElementNode] {
        [self] + children.flatMap { $0.flattenedDescendants() }
    }

    /// Every name in the tree, used to detect change: navigation often changes
    /// content without changing the buttons.
    var namedElementFingerprint: Set<String> {
        Set(flattenedDescendants().compactMap { $0.displayName?.forDisplay })
    }
}
