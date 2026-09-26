//
//  AccessibilityStatusItems.swift
//  Go
//
//  The status icons on the right of the menu bar, read from every process
//  that owns one (`AXExtrasMenuBar`).
//

import AppKit
import ApplicationServices

nonisolated enum AccessibilityStatusItems {

    static let extrasMenuBarAttribute = "AXExtrasMenuBar"
    static let identifierAttribute = "AXIdentifier"
    static let messagingTimeoutInSeconds: Float = 0.5

    /// One item without its live handle, so tests can build it.
    struct Descriptor: Equatable {
        let ownerName: String?
        let ownerBundleIdentifier: String?
        let ownerProcessIdentifier: pid_t
        let identifier: String?
        let title: UntrustedText?
        let elementDescription: UntrustedText?
        let value: UntrustedText?
        let isEnabled: Bool
        /// Never gated on: in a full-screen Space the bar is off-screen but still works.
        let frameInAppKitCoordinates: CGRect
        let publishedActionNames: [String]
        /// Some items carry one readable `AXMenu` child; Control Centre's don't.
        let hasMenu: Bool

        init(
            ownerName: String?,
            ownerBundleIdentifier: String?,
            ownerProcessIdentifier: pid_t = 0,
            identifier: String?,
            title: String?,
            elementDescription: String?,
            value: String? = nil,
            isEnabled: Bool = true,
            frameInAppKitCoordinates: CGRect = .zero,
            publishedActionNames: [String] = [kAXPressAction as String],
            hasMenu: Bool = false
        ) {
            func present(_ text: String?) -> String? { (text?.isEmpty == false) ? text : nil }
            self.ownerName = present(ownerName)
            self.ownerBundleIdentifier = present(ownerBundleIdentifier)
            self.ownerProcessIdentifier = ownerProcessIdentifier
            self.identifier = present(identifier)
            self.title = present(title).map(UntrustedText.init)
            self.elementDescription = present(elementDescription).map(UntrustedText.init)
            self.value = present(value).map(UntrustedText.init)
            self.isEnabled = isEnabled
            self.frameInAppKitCoordinates = frameInAppKitCoordinates
            self.publishedActionNames = publishedActionNames
            self.hasMenu = hasMenu
        }

        /// Identifier, then title, then description, then the owning app.
        var bestName: String {
            identifier ?? title?.raw ?? elementDescription?.raw ?? "<owner: \(ownerName ?? ownerBundleIdentifier ?? "pid \(ownerProcessIdentifier)")>"
        }
    }

    struct Item {
        let descriptor: Descriptor
        let element: AXUIElement
    }

    // MARK: - Matching

    enum MatchTier: String {
        case identifier, name, owner
    }

    enum Resolution: Equatable {
        case resolved(index: Int, tier: MatchTier)
        case ambiguous(matchCount: Int, tier: MatchTier)
        case notFound(available: [String])
    }

    /// First tier with a match wins; several in a tier is ambiguous. Exact and
    /// case-insensitive only.
    static func match(_ query: String, among candidates: [Descriptor]) -> Resolution {
        let wanted = query.lowercased()
        let tiers: [(MatchTier, (Descriptor) -> Bool)] = [
            (.identifier, { $0.identifier?.lowercased() == wanted }),
            (.name, { $0.title?.raw.lowercased() == wanted || $0.elementDescription?.raw.lowercased() == wanted }),
            (.owner, { $0.ownerBundleIdentifier?.lowercased() == wanted || $0.ownerName?.lowercased() == wanted })
        ]
        for (tier, matches) in tiers {
            let indices = candidates.indices.filter { matches(candidates[$0]) }
            switch indices.count {
            case 0: continue
            case 1: return .resolved(index: indices[0], tier: tier)
            default: return .ambiguous(matchCount: indices.count, tier: tier)
            }
        }
        return .notFound(available: candidates.map(\.bestName).sorted())
    }

    // MARK: - Security

    /// A password manager's status item opens the password list: refused.
    static let secureOwnerBundleIdentifiers: Set<String> = ["com.apple.Passwords.MenuBarExtra"]

    static func isSecure(_ descriptor: Descriptor) -> Bool {
        descriptor.ownerBundleIdentifier.map(secureOwnerBundleIdentifiers.contains) ?? false
    }

    // MARK: - Live reads

    static let batchedAttributes: [String] = [
        kAXRoleAttribute as String, kAXTitleAttribute as String, kAXDescriptionAttribute as String,
        kAXValueAttribute as String, identifierAttribute, AccessibilityMenu.enabledAttribute,
        AccessibilityWindows.frameAttribute, kAXChildrenAttribute as String
    ]

    /// "No such attribute" means no status item; other errors mean unreadable.
    static func isAbsence(_ error: AXError) -> Bool {
        error == .noValue || error == .attributeUnsupported
    }

    struct ReadAll {
        let items: [Item]
        let processesAsked: Int
        let processesAnswered: Int
        let processesFailed: [(name: String, axErrorRawValue: Int32)]
        let childrenFailed: Int
        let milliseconds: Int
    }

    /// Every status item, from regular and accessory processes (the rest have none).
    static func readAll() -> ReadAll {
        let startedAt = Date()
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), messagingTimeoutInSeconds)
        let primaryDisplayHeight = CGDisplayBounds(CGMainDisplayID()).height

        var items: [Item] = []
        var asked = 0
        var answered = 0
        var failed: [(name: String, axErrorRawValue: Int32)] = []
        var childrenFailed = 0
        for application in NSWorkspace.shared.runningApplications
        where application.activationPolicy == .regular || application.activationPolicy == .accessory {
            asked += 1
            let processName = application.localizedName ?? application.bundleIdentifier ?? "pid \(application.processIdentifier)"
            let applicationElement = AXUIElementCreateApplication(application.processIdentifier)
            var barValue: AnyObject?
            let barError = AXUIElementCopyAttributeValue(applicationElement, extrasMenuBarAttribute as CFString, &barValue)
            guard barError == .success else {
                if !isAbsence(barError) { failed.append((processName, barError.rawValue)) }
                continue
            }
            guard let barValue, CFGetTypeID(barValue) == AXUIElementGetTypeID() else { continue }
            var childrenValue: AnyObject?
            let childrenError = AXUIElementCopyAttributeValue(barValue as! AXUIElement, kAXChildrenAttribute as CFString, &childrenValue)
            guard childrenError == .success else {
                if !isAbsence(childrenError) { failed.append((processName, childrenError.rawValue)) }
                continue
            }
            guard let children = childrenValue as? [AXUIElement] else { continue }
            answered += 1

            for child in children {
                var rawValues: CFArray?
                let batchResult = AXUIElementCopyMultipleAttributeValues(
                    child, batchedAttributes as CFArray, AXCopyMultipleAttributeOptions(), &rawValues
                )
                guard batchResult == .success else { childrenFailed += 1; continue }
                let values = (rawValues as? [AnyObject]) ?? []
                func entry(_ index: Int) -> AnyObject? {
                    guard index < values.count else { return nil }
                    let value = values[index]
                    // A failed attribute is an AXValue wrapping an AXError.
                    if CFGetTypeID(value) == AXValueGetTypeID(),
                       AXValueGetType(value as! AXValue) == .axError { return nil }
                    return value
                }
                guard (entry(0) as? String) == AccessibilityMenu.menuBarItemRole else { continue }

                var frame = CGRect.zero
                if let frameValue = entry(6), CFGetTypeID(frameValue) == AXValueGetTypeID() {
                    var rect = CGRect.zero
                    if AXValueGetValue(frameValue as! AXValue, .cgRect, &rect) { frame = rect }
                }

                items.append(Item(
                    descriptor: Descriptor(
                        ownerName: application.localizedName,
                        ownerBundleIdentifier: application.bundleIdentifier,
                        ownerProcessIdentifier: application.processIdentifier,
                        identifier: entry(4) as? String,
                        title: entry(1) as? String,
                        elementDescription: entry(2) as? String,
                        value: entry(3) as? String,
                        isEnabled: (entry(5) as? Bool) ?? true,
                        frameInAppKitCoordinates: AccessibilityTreeWalker.convertAccessibilityFrameToAppKitFrame(
                            frame, primaryDisplayHeightInPoints: primaryDisplayHeight
                        ),
                        publishedActionNames: AccessibilityTreeWalker.copyActionNames(from: child),
                        hasMenu: !((entry(7) as? [AXUIElement]) ?? []).isEmpty
                    ),
                    element: child
                ))
            }
        }
        return ReadAll(
            items: items, processesAsked: asked, processesAnswered: answered,
            processesFailed: failed, childrenFailed: childrenFailed,
            milliseconds: Int(Date().timeIntervalSince(startedAt) * 1000)
        )
    }

    /// `AXSelected` on the item; some menus change only this when opened.
    static func isSelected(_ element: AXUIElement) -> Bool {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedAttribute as CFString, &value) == .success else { return false }
        return (value as? Bool) ?? false
    }

    static func childCount(of element: AXUIElement) -> Int {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success else { return 0 }
        return (value as? [AXUIElement])?.count ?? 0
    }
}
