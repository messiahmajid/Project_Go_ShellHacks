//
//  ActionSafetyKernel.swift
//  Go
//
//  Deterministic policy that runs before any action. Unknown cases become a
//  question for the user, never an allow.
//

import ApplicationServices
import Foundation

nonisolated enum SafetyDecision: Equatable {
    case allow
    /// Set by the kernel when a question is about destroying something. A flag,
    /// not a reason prefix, so it survives layers that rewrite the reason.
    case requireConfirmation(reason: String, destructive: Bool = false)
    case refuse(reason: String)
}

nonisolated enum ActionSafetyKernel {

    /// Roles for which a press is ordinary navigation. Destructive titles still
    /// ask and irreversible ones are still refused.
    static let navigationalPressRoles: Set<String> = ["AXButton", "AXRow", "AXCell", "AXMenuItem"]

    /// Roles for which selecting is ordinary navigation. `AXStaticText` is here
    /// because sidebar rows are anonymous and only their inner label has a name.
    static let navigationalSelectRoles: Set<String> = ["AXRow", "AXCell", "AXStaticText"]

    /// The only roles that may be typed into; anything else is refused.
    static let typeableRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox"]

    /// Opening (`AXOpen`) launches whatever the item is, so it always asks.
    static let navigationalOpenRoles: Set<String> = []

    /// Roles a menu path resolves to.
    static let navigationalMenuRoles: Set<String> = ["AXMenuItem", "AXMenuBarItem"]

    static let secureFieldSubrole = "AXSecureTextField"

    static func navigationalRoles(for action: ElementAction) -> Set<String> {
        switch action {
        case .press: return navigationalPressRoles
        case .select: return navigationalSelectRoles
        case .type: return typeableRoles
        case .open: return navigationalOpenRoles
        case .menu: return navigationalMenuRoles
        }
    }

    /// Facts about a typing target that the tree walk does not carry.
    struct TypingContext: Equatable {
        let mode: TypeMode
        /// Attributes the element reported as settable.
        let settableAttributes: Set<String>
        let currentValueLength: Int
        /// True when the target came from the focused element rather than a name,
        /// so name checks do not apply.
        let aimedByFocus: Bool
    }

    static func secureFieldRefusalReason(subrole: String) -> String {
        "refusing to type into a secure field (subrole \(subrole)) — the agent does not enter credentials, and this refusal has no confirmed path past it"
    }

    /// Whether a refusal looks like an attempt to do something unsafe (as opposed
    /// to something impossible). The audit log keeps more context for these.
    static func isSecurityRefusal(reason: String) -> Bool {
        reason == implausibleNameRefusalReason
            || reason == secureStatusItemRefusalReason
            || reason.hasPrefix("refusing to type into a secure field")
            || reason.hasPrefix(secureFieldCaptureRefusalPrefix)
            || reason.hasPrefix(incompleteCaptureCheckRefusalPrefix)
            || reason.hasPrefix(irreversibleRefusalPrefix)
    }

    static func nonTextRoleRefusalReason(role: String) -> String {
        "role \(role) does not accept text — only \(typeableRoles.sorted().joined(separator: ", ")) may be typed into"
    }

    static func missingSettableAttributeRefusalReason(attribute: String) -> String {
        "element does not publish a settable \(attribute)"
    }

    static func replaceWouldDiscardReason(characterCount: Int) -> String {
        "\(replaceWouldDiscardReasonPrefix)\(characterCount) characters already in the field"
    }

    /// Destructive questions may be answered once, never "always": a rule cannot
    /// remember what was selected.
    static let destructiveActionReasonPrefix = "title suggests a destructive action: "
    static let replaceWouldDiscardReasonPrefix = "replace would discard "

    static let shortSingleLineValueLimit = 200

    static let zeroAreaRefusalReason = "listed but not reachable: element has a zero-area frame"
    static let outsideBoundsRefusalReason = "listed but not reachable: element lies outside the visible bounds"

    /// Why a frame is out of reach, or nil when a person could click it.
    static func unreachableFrameReason(_ frame: CGRect, visibleBounds: CGRect) -> String? {
        guard frame.width > 0, frame.height > 0 else { return zeroAreaRefusalReason }
        // A named, correctly sized element can still be scrolled out of its pane.
        guard frame.intersects(visibleBounds) else { return outsideBoundsRefusalReason }
        return nil
    }

    /// An empty, very long or multi-line "name" is content, not a label, and
    /// must never name an action.
    static let implausibleNameRefusalReason = "listed but not usable as a target: the element's name is not a plain label"

    /// A disabled menu item "succeeds" when pressed and does nothing, so ask first.
    static func menuItemDisabledRefusalReason(name: String) -> String {
        "menu item \(name) is disabled (AXEnabled false) — pressing it would return success and do nothing"
    }

    /// Titles that are refused outright: nothing undoes them, so the user does
    /// these by hand. Kept disjoint from `destructiveTitleKeywords` (tested).
    static let irreversibleTitleKeywords = [
        "empty trash", "empty bin",
        "delete immediately", "permanently",
        // Also catches an "Eraser" tool; a false positive costs one manual click.
        "erase",
        "buy", "pay", "purchase"
    ]

    static let irreversibleRefusalPrefix = "refusing an irreversible action"

    static func irreversibleRefusalReason(keyword: String) -> String {
        "\(irreversibleRefusalPrefix): the title contains \"\(keyword)\" — this has no undo, "
            + "so it has no confirmed path past it either; a human does this one themselves"
    }

    /// Titles that make an action worth asking about, whatever the role.
    static let destructiveTitleKeywords = [
        "delete", "remove", "send", "reset",
        // "close" is deliberately absent: closing a window is ordinary.
        "trash", "quit", "empty", "eject", "log out", "shut down",
        "move to bin"
    ]

    /// Focus has no control to check. Two rules apply: several matching windows
    /// is a question, and the title must be a plain label.
    static func evaluateFocus(windowTitle: UntrustedText?, matchCount: Int) -> SafetyDecision {
        guard matchCount == 1 else {
            return .refuse(reason: "\(matchCount) windows match that title")
        }
        if let windowTitle, !windowTitle.isPlausibleControlLabel {
            return .refuse(reason: implausibleNameRefusalReason)
        }
        return .allow
    }

    static let launchConfirmationBundleIdentifiers: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "com.apple.ScriptEditor2",
        "com.apple.Automator", "com.apple.shortcuts", "com.apple.installer",
        "com.apple.keychainaccess", "com.apple.Passwords"
    ]

    /// Launch targets an installed app by identity, never a file, so it is allowed
    /// where opening asks. Matching is case-insensitive, like LaunchServices.
    static func evaluateLaunch(bundleIdentifier: String) -> SafetyDecision {
        if launchConfirmationBundleIdentifiers.contains(where: {
            $0.caseInsensitiveCompare(bundleIdentifier) == .orderedSame
        }) {
            return .requireConfirmation(
                reason: "launching \(bundleIdentifier) — it runs arbitrary code or holds credentials"
            )
        }
        return .allow
    }

    static let secureFieldCaptureRefusalPrefix = "refusing to capture a region containing a secure field"

    /// A password manager's status item opens the password list: refused like a
    /// secure field.
    static let secureStatusItemRefusalReason = "refusing to press a credential manager's status item, like a secure field"

    /// Whether a region may be captured. Password fields are never photographed,
    /// and an incomplete inspection counts as a refusal, not a pass.
    static func evaluateCapture(_ inspection: CaptureInspection) -> SafetyDecision {
        // A secure field that was seen is refused even if the walk stopped early.
        if inspection.windows.contains(where: { window in
            window.nodes.contains(where: { $0.subrole == secureFieldSubrole })
        }) {
            return .refuse(reason: "\(secureFieldCaptureRefusalPrefix) (subrole \(secureFieldSubrole))")
        }
        if let incomplete = inspection.incompleteReason {
            return .refuse(reason: incomplete)
        }
        return .allow
    }

    static let incompleteCaptureCheckRefusalPrefix =
        "refusing to capture: the secure-field check could not inspect the whole region"

    static func evaluate(
        intent: ElementActionIntent,
        resolvedNode: AccessibilityElementNode,
        matchCount: Int,
        visibleBounds: CGRect,
        typing: TypingContext? = nil,
        menuItemEnabled: Bool? = nil
    ) -> SafetyDecision {
        // Every refusal is checked before any permission.

        // A password field is refused on sight; nothing overrides it.
        if case .type = intent.action,
           let subrole = resolvedNode.subrole, subrole == secureFieldSubrole {
            return .refuse(reason: secureFieldRefusalReason(subrole: subrole))
        }

        // Irreversible titles are refused before the reachability and enabled checks,
        // so a refusal never reads like "try again later".
        if intent.action.irreversibleNamesAreRefused,
           typing?.aimedByFocus != true,
           let name = resolvedNode.displayName {
            let lowercased = name.raw.lowercased()
            if let matchedKeyword = irreversibleTitleKeywords.first(where: { lowercased.contains($0) }) {
                return .refuse(reason: irreversibleRefusalReason(keyword: matchedKeyword))
            }
        }

        guard matchCount == 1 else {
            return .refuse(reason: "\(matchCount) elements match that title")
        }

        // Closed menu items report a zero frame, so frame checks apply only to
        // verbs whose target is on screen.
        let frame = resolvedNode.frameInAppKitCoordinates
        if intent.action.targetHasAnOnScreenFrame,
           let reason = unreachableFrameReason(frame, visibleBounds: visibleBounds) {
            return .refuse(reason: reason)
        }

        // Only actions have action names; property writes are checked at write time.
        if let requiredActionName = intent.action.accessibilityActionName {
            guard resolvedNode.publishedActionNames.contains(requiredActionName) else {
                return .refuse(reason: "element does not publish \(requiredActionName)")
            }
        }

        if case .menu = intent.action {
            // No answer means we never asked: our bug, not a question for the user.
            guard let menuItemEnabled else {
                return .refuse(reason: "no enabled state was read for this menu item")
            }
            guard menuItemEnabled else {
                return .refuse(reason: menuItemDisabledRefusalReason(
                    name: resolvedNode.displayName?.forDisplay ?? "?"
                ))
            }
        }

        if case .type = intent.action {
            guard typeableRoles.contains(resolvedNode.role) else {
                return .refuse(reason: nonTextRoleRefusalReason(role: resolvedNode.role))
            }
            guard let typing else {
                return .refuse(reason: "no typing context was gathered for this element")
            }
            let required = typing.mode.settableAttributeRequired
            guard typing.settableAttributes.contains(required) else {
                return .refuse(reason: missingSettableAttributeRefusalReason(attribute: required))
            }
        }

        // A field found by focus is identified by the OS; it may have no name.
        if typing?.aimedByFocus != true {
            guard let name = resolvedNode.displayName, name.isPlausibleControlLabel else {
                return .refuse(reason: implausibleNameRefusalReason)
            }

            // App-written text can only make the decision more cautious.
            let lowercasedTitle = name.raw.lowercased()

            if let matchedKeyword = destructiveTitleKeywords.first(where: { lowercasedTitle.contains($0) }) {
                return .requireConfirmation(reason: "\(destructiveActionReasonPrefix)\(matchedKeyword)", destructive: true)
            }
        }

        // Replacing text in a non-empty field asks first. Short single-line values
        // (a name, a title) are not destructive, so trusted mode may approve them.
        if let typing, typing.mode == .replace, typing.currentValueLength > 0 {
            let singleLine = resolvedNode.role == kAXTextFieldRole || resolvedNode.role == kAXComboBoxRole
            return .requireConfirmation(
                reason: replaceWouldDiscardReason(characterCount: typing.currentValueLength),
                destructive: !(singleLine && typing.currentValueLength <= Self.shortSingleLineValueLimit)
            )
        }

        guard navigationalRoles(for: intent.action).contains(resolvedNode.role) else {
            return .requireConfirmation(reason: "unrecognised role \(resolvedNode.role)")
        }

        return .allow
    }
}

/// What the secure-field check inspected before a capture.
nonisolated struct CaptureInspection {
    struct WindowWalk {
        var title: UntrustedText? = nil
        var role: String? = nil
        var nodes: [AccessibilityElementNode] = []
        /// Which limits stopped the walk; empty means it finished.
        var stopReasons: Set<WalkStopReason> = []
        var subtreesLostToFailedReads = 0
        var failure: String? = nil
    }

    /// The error when the window list could not be read (unknown, not empty).
    var windowListReadError: Int32? = nil
    var windows: [WindowWalk] = []

    /// Whether a one-app capture of this region would show anything. Finder's
    /// desktop alone captures as a blank image.
    var containsDrawableWindow: Bool {
        windows.contains { $0.role == kAXWindowRole as String }
    }

    /// Why this inspection does not cover the region, or nil when it does.
    var incompleteReason: String? {
        let prefix = ActionSafetyKernel.incompleteCaptureCheckRefusalPrefix
        if let code = windowListReadError {
            return "\(prefix) — kAXWindows failed with AXError \(code), so which windows cover it is unknown"
        }
        for (index, window) in windows.enumerated() {
            var gaps: [String] = []
            if let failure = window.failure { gaps.append("could not be walked (\(failure))") }
            gaps += window.stopReasons.map(\.rawValue).sorted()
            if window.subtreesLostToFailedReads > 0 {
                gaps.append("lost \(window.subtreesLostToFailedReads) subtree(s) to failed children reads")
            }
            // Only text fields can be password boxes, so failed reads elsewhere don't count.
            let unreadableTextFields = window.nodes.filter {
                ActionSafetyKernel.typeableRoles.contains($0.role) && $0.subroleReadFailed
            }.count
            if unreadableTextFields > 0 {
                gaps.append("has \(unreadableTextFields) text field(s) whose subrole could not be read, "
                    + "any of which may be a password field")
            }
            guard !gaps.isEmpty else { continue }
            let name = window.title?.forDisplay ?? "#\(index) (untitled)"
            return "\(prefix) — window \(name) \(gaps.joined(separator: ", "))"
        }
        return nil
    }
}
