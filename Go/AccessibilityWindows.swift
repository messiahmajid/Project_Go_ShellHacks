//
//  AccessibilityWindows.swift
//  Go
//
//  Listing an app's windows and bringing one forward (`windows` and `focus`).
//  Resolution is pure over small value types; the live reads are separate.
//

import AppKit
import ApplicationServices
import Foundation

nonisolated enum AccessibilityWindows {

    /// How long to wait for a Space switch to make an app's windows readable.
    static let spaceSwitchDeadlineInSeconds: TimeInterval = 2.0

    static let messagingTimeoutInSeconds: Float = 0.5

    static let minimizedAttribute = kAXMinimizedAttribute as String
    static let mainAttribute = kAXMainAttribute as String
    static let frameAttribute = "AXFrame"

    /// How long `focus` waits to see that it worked, and how often it checks.
    static let observationDeadlineInSeconds = 2.0
    static let observationPollIntervalInMicroseconds: UInt32 = 50_000

    // MARK: - Application resolution

    /// One running app, flattened so matching is testable.
    struct ApplicationCandidate: Equatable {
        let bundleIdentifier: String?
        let localizedName: String?
        /// The `.app` folder name, which can differ from the running name
        /// ("Visual Studio Code" vs "Code").
        let bundleName: String?
        let isActive: Bool
        let isHidden: Bool

        init(
            bundleIdentifier: String?, localizedName: String?, bundleName: String? = nil,
            isActive: Bool = false, isHidden: Bool = false
        ) {
            self.bundleIdentifier = bundleIdentifier
            self.localizedName = localizedName
            self.bundleName = bundleName
            self.isActive = isActive
            self.isHidden = isHidden
        }
    }

    /// Which field the query matched on.
    enum ApplicationMatchTier: String, Equatable, CaseIterable {
        case bundleIdentifier
        case name
        case bundleName
        case namePrefix
    }

    enum ApplicationResolution: Equatable {
        case resolved(index: Int, tier: ApplicationMatchTier)
        case notFound(available: [String])
        case ambiguous(matchCount: Int, tier: ApplicationMatchTier)
    }

    /// Bundle id, then name, then prefix: the first tier with a match wins, so an
    /// exact name never loses to a prefix. Two matches in a tier is a question.
    static func matchApplication(
        _ query: String,
        among candidates: [ApplicationCandidate]
    ) -> ApplicationResolution {
        let wanted = query.lowercased()

        let tiers: [(ApplicationMatchTier, (ApplicationCandidate) -> Bool)] = [
            (.bundleIdentifier, { $0.bundleIdentifier?.lowercased() == wanted }),
            (.name, { $0.localizedName?.lowercased() == wanted }),
            (.bundleName, { $0.bundleName?.lowercased() == wanted }),
            (.namePrefix, { $0.localizedName?.lowercased().hasPrefix(wanted) ?? false })
        ]

        for (tier, matches) in tiers {
            let indices = candidates.indices.filter { matches(candidates[$0]) }
            switch indices.count {
            case 0: continue
            case 1: return .resolved(index: indices[0], tier: tier)
            default: return .ambiguous(matchCount: indices.count, tier: tier)
            }
        }
        return .notFound(available: candidates.compactMap(\.localizedName).sorted())
    }

    // MARK: - Window resolution

    /// One window, flattened. `title` is app-written.
    struct WindowCandidate: Equatable {
        let title: UntrustedText?
        let role: String
        let subrole: String?
        let isMain: Bool
        let isMinimized: Bool
        /// AppKit coordinates, converted in `liveWindows`.
        let frameInAppKitCoordinates: CGRect
        let publishedActionNames: [String]

        init(
            title: String?,
            role: String = "AXWindow",
            subrole: String? = nil,
            isMain: Bool = false,
            isMinimized: Bool = false,
            frameInAppKitCoordinates: CGRect = .zero,
            publishedActionNames: [String] = []
        ) {
            self.title = title.map(UntrustedText.init)
            self.role = role
            self.subrole = subrole
            self.isMain = isMain
            self.isMinimized = isMinimized
            self.frameInAppKitCoordinates = frameInAppKitCoordinates
            self.publishedActionNames = publishedActionNames
        }
    }

    enum WindowResolution: Equatable {
        case resolved(index: Int)
        case notFound(available: [String])
        case ambiguous(matchCount: Int)
    }

    /// Exact title, then substring (apps decorate titles), then the point if still
    /// ambiguous. The point narrows only by containment, never "nearest".
    static func matchWindow(
        title: String,
        nearPoint: CGPoint?,
        among candidates: [WindowCandidate]
    ) -> WindowResolution {
        let wanted = title.lowercased()

        var indices = candidates.indices.filter { candidates[$0].title?.raw.lowercased() == wanted }
        if indices.isEmpty {
            indices = candidates.indices.filter {
                candidates[$0].title?.raw.lowercased().contains(wanted) ?? false
            }
        }

        switch indices.count {
        case 0:
            return .notFound(available: candidates.compactMap { $0.title?.raw })
        case 1:
            return .resolved(index: indices[0])
        default:
            if let nearPoint {
                let containing = indices.filter {
                    candidates[$0].frameInAppKitCoordinates.contains(nearPoint)
                }
                if containing.count == 1 { return .resolved(index: containing[0]) }
            }
            return .ambiguous(matchCount: indices.count)
        }
    }

    // MARK: - Live reads

    /// Every regular running app, excluding the lock screen.
    static func runningApplications() -> [(application: NSRunningApplication, candidate: ApplicationCandidate)] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .filter { !LockScreenGuard.isLockScreen($0.bundleIdentifier) }
            .map { application in
                (application, ApplicationCandidate(
                    bundleIdentifier: application.bundleIdentifier,
                    localizedName: application.localizedName,
                    bundleName: application.bundleURL?.deletingPathExtension().lastPathComponent,
                    isActive: application.isActive,
                    isHidden: application.isHidden
                ))
            }
    }

    private static func copyValue(_ element: AXUIElement, _ attribute: String) -> AnyObject? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value
    }

    /// What `kAXWindows` answered, and separately whether it answered at all:
    /// zero windows is only a fact if the read worked.
    struct WindowRead {
        var windows: [(element: AXUIElement, candidate: WindowCandidate)] = []
        /// `.success` with an empty list means no windows; anything else means unknown.
        var error: AXError = .success
        var readSucceeded: Bool { error == .success }
    }

    static func liveWindows(for application: NSRunningApplication) -> WindowRead {
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), messagingTimeoutInSeconds)

        let applicationElement = AXUIElementCreateApplication(application.processIdentifier)
        var value: AnyObject?
        let error = AXUIElementCopyAttributeValue(
            applicationElement, kAXWindowsAttribute as CFString, &value
        )
        guard error == .success, let windows = value as? [AXUIElement] else {
            // These two errors mean genuinely empty; others are read failures.
            let genuinelyEmpty = (error == .noValue || error == .attributeUnsupported)
            return WindowRead(windows: [], error: genuinelyEmpty ? .success : error)
        }
        let primaryDisplayHeight = CGDisplayBounds(CGMainDisplayID()).height

        let candidates = windows.map { window in
            var accessibilityFrame = CGRect.zero
            if let frameValue = copyValue(window, frameAttribute),
               CFGetTypeID(frameValue) == AXValueGetTypeID() {
                var rect = CGRect.zero
                if AXValueGetValue(frameValue as! AXValue, .cgRect, &rect) { accessibilityFrame = rect }
            }

            let title = copyValue(window, kAXTitleAttribute as String) as? String
            return (window, WindowCandidate(
                title: (title?.isEmpty == false) ? title : nil,
                role: (copyValue(window, kAXRoleAttribute as String) as? String) ?? "AXUnknown",
                subrole: copyValue(window, kAXSubroleAttribute as String) as? String,
                isMain: (copyValue(window, mainAttribute) as? Bool) ?? false,
                isMinimized: (copyValue(window, minimizedAttribute) as? Bool) ?? false,
                frameInAppKitCoordinates: AccessibilityTreeWalker.convertAccessibilityFrameToAppKitFrame(
                    accessibilityFrame, primaryDisplayHeightInPoints: primaryDisplayHeight
                ),
                publishedActionNames: AccessibilityTreeWalker.copyActionNames(from: window)
            ))
        }
        return WindowRead(windows: candidates, error: .success)
    }

    /// Brings the app forward and waits until its window list is readable.
    /// `kAXWindows` only lists windows on the current Space, so a window can't be
    /// resolved by name until its app is in front.
    static func activateAndWaitForWindows(
        _ application: NSRunningApplication
    ) -> (activated: Bool, read: WindowRead, milliseconds: Int) {
        let startedAt = Date()
        let activated = application.activate()
        let deadline = startedAt.addingTimeInterval(spaceSwitchDeadlineInSeconds)
        var read = liveWindows(for: application)
        while read.windows.isEmpty, Date() < deadline {
            usleep(observationPollIntervalInMicroseconds)
            read = liveWindows(for: application)
        }
        return (activated, read, Int(Date().timeIntervalSince(startedAt) * 1000))
    }

    // MARK: - Focus

    /// Each step's outcome, reported separately. `observed` (asking the OS who is
    /// frontmost) is the one that decides.
    struct FocusOutcome {
        /// Minimized windows are restored before raising.
        var unminimized = false
        var unminimizeErrorRawValue: Int32?

        /// Whether the window published `AXRaise`; activating alone is a partial result.
        var raisePublished = false
        var raiseErrorRawValue: Int32?
        var raiseMilliseconds: Int?

        var activated = false
        /// Time spent acting, so the harness can split it from waiting.
        var actMilliseconds = 0

        var readBackMain: Bool?
        var observed = false
        var observedMilliseconds = 0
        var observedApplication: String?
        /// Which read matched on the last poll.
        var observedVia: String?
        var observedWindowTitle: UntrustedText?
        var observationPolls = 0
    }

    /// The frontmost app before anything moves, so the user can go back.
    static func previousApplication() -> (name: String?, bundleIdentifier: String?)? {
        guard let application = AccessibilityTreeWalker.focusedApplication() else { return nil }
        return (application.localizedName, application.bundleIdentifier)
    }

    /// Raise the window if given, activate the app, then check. A nil window
    /// means just activate the app.
    static func focus(
        application: NSRunningApplication,
        window: (element: AXUIElement, candidate: WindowCandidate)?
    ) -> FocusOutcome {
        var outcome = FocusOutcome()
        let actStartedAt = Date()

        if let window {
            if window.candidate.isMinimized {
                let error = AXUIElementSetAttributeValue(
                    window.element, minimizedAttribute as CFString, kCFBooleanFalse
                )
                outcome.unminimized = error == .success
                outcome.unminimizeErrorRawValue = error.rawValue
            }

            outcome.raisePublished = window.candidate.publishedActionNames.contains(kAXRaiseAction as String)
            if outcome.raisePublished {
                // The performer raises the timeout for this element; raising animates.
                let result = AccessibilityActionPerformer.perform(kAXRaiseAction as String, on: window.element)
                outcome.raiseErrorRawValue = result.error.rawValue
                outcome.raiseMilliseconds = result.milliseconds
            }
        }

        outcome.activated = application.activate()
        outcome.actMilliseconds = Int(Date().timeIntervalSince(actStartedAt) * 1000)

        if let window {
            outcome.readBackMain = copyValue(window.element, mainAttribute) as? Bool
        }

        // Ask the OS, on a deadline. The window is compared by element identity,
        // since two windows can share a title.
        let wantedProcessIdentifier = application.processIdentifier
        let wantedWindow = window.map { AccessibilityElementKey(element: $0.element) }
        let applicationElement = AXUIElementCreateApplication(application.processIdentifier)
        let startedAt = Date()
        let deadline = startedAt.addingTimeInterval(observationDeadlineInSeconds)

        repeat {
            outcome.observationPolls += 1
            // Ask Accessibility who is focused (live); `NSWorkspace` is a cache that can
            // lag. Electron apps may not answer the system-wide read until their
            // accessibility is on, so the app is asked directly as a fallback.
            var focusedApplication: AXUIElement?
            if let value = copyValue(AXUIElementCreateSystemWide(), kAXFocusedApplicationAttribute as String),
               CFGetTypeID(value) == AXUIElementGetTypeID() {
                focusedApplication = (value as! AXUIElement)
            }
            var focusedProcessIdentifier: pid_t = -1
            if let focusedApplication {
                AXUIElementGetPid(focusedApplication, &focusedProcessIdentifier)
            }
            outcome.observedApplication = NSRunningApplication(
                processIdentifier: focusedProcessIdentifier
            )?.localizedName

            var focusedWindow: AccessibilityElementKey?
            if let focused = copyValue(applicationElement, kAXFocusedWindowAttribute as String),
               CFGetTypeID(focused) == AXUIElementGetTypeID() {
                let element = focused as! AXUIElement
                focusedWindow = AccessibilityElementKey(element: element)
                outcome.observedWindowTitle = (copyValue(element, kAXTitleAttribute as String) as? String)
                    .map(UntrustedText.init)
            } else {
                outcome.observedWindowTitle = nil
            }

            // Ask the app only when the system-wide read gave no answer.
            if focusedProcessIdentifier == wantedProcessIdentifier {
                outcome.observedVia = "systemWide"
            } else if focusedApplication == nil,
                      copyValue(applicationElement, kAXFrontmostAttribute as String) as? Bool == true {
                outcome.observedVia = "applicationFrontmost"
            } else {
                outcome.observedVia = nil
            }
            let applicationMatches = outcome.observedVia != nil
            let windowMatches = wantedWindow == nil || focusedWindow == wantedWindow
            if applicationMatches && windowMatches {
                outcome.observed = true
                break
            }
            usleep(observationPollIntervalInMicroseconds)
        } while Date() < deadline

        outcome.observedMilliseconds = Int(Date().timeIntervalSince(startedAt) * 1000)
        return outcome
    }
}
