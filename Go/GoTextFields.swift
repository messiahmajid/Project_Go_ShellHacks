import AppKit
import ApplicationServices

/// A text-entry control the owner can type into. Only its label (title,
/// description, placeholder or linked label) is kept — never its contents.
/// Password fields are never listed.
nonisolated struct GoTextField: Codable, Equatable, Sendable {
    let id: String
    let role: String
    let label: String
    let focused: Bool
    let x: Double, y: Double, w: Double, h: Double

    var frame: CGRect { CGRect(x: x, y: y, width: w, height: h) }
}

/// Read-only AX reads for typing steps. The general snapshot can fall back to
/// a field's value as its name, so fields are listed here instead, and field
/// contents are read only locally to check a typing step — never logged or sent.
nonisolated enum GoTextFields {
    static let roles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox"]

    static func list(app bundleIdentifier: String, limit: Int = 20) -> [GoTextField] {
        guard let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first else { return [] }
        let application = AXUIElementCreateApplication(running.processIdentifier)
        AXUIElementSetMessagingTimeout(application, 0.25)
        let focused: AXUIElement? = value(application, kAXFocusedUIElementAttribute)
        var found: [AXUIElement] = []
        if let window: AXUIElement = value(application, kAXFocusedWindowAttribute) {
            var queue: [(AXUIElement, Int)] = [(window, 0)]
            var visited = 0
            // Large web pages can hold thousands of nodes; planning must not wait on this walk.
            let deadline = ProcessInfo.processInfo.systemUptime + 0.25
            while !queue.isEmpty, visited < 900, found.count < limit, ProcessInfo.processInfo.systemUptime < deadline {
                let (element, depth) = queue.removeFirst()
                visited += 1
                if isTypeable(element) { found.append(element); continue }
                guard depth < 25 else { continue }
                let children: [AXUIElement] = value(element, kAXChildrenAttribute) ?? []
                queue += children.map { ($0, depth + 1) }
            }
        }
        if let focused, isTypeable(focused), !found.contains(where: { CFEqual($0, focused) }) { found.append(focused) }
        let primaryHeight = CGDisplayBounds(CGMainDisplayID()).height
        return found.enumerated().compactMap { index, element in
            guard let axFrame = AccessibilityTreeWalker.copyFrame(from: element).frame,
                  axFrame.width > 0, axFrame.height > 0, axFrame.origin.x.isFinite, axFrame.origin.y.isFinite else { return nil }
            let rect = AccessibilityTreeWalker.convertAccessibilityFrameToAppKitFrame(axFrame, primaryDisplayHeightInPoints: primaryHeight)
            return GoTextField(id: "t\(index)", role: value(element, kAXRoleAttribute) ?? "AXTextField", label: label(of: element),
                               focused: focused.map { CFEqual($0, element) } ?? false,
                               x: rect.minX, y: rect.minY, w: rect.width, h: rect.height)
        }
    }

    /// The contents of the typeable field under the centre of `rect`, for a
    /// local comparison only. Nil for password fields or anything else.
    static func contents(at rect: CGRect) -> String? {
        let primaryHeight = CGDisplayBounds(CGMainDisplayID()).height
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, 0.25)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(systemWide, Float(rect.midX), Float(primaryHeight - rect.midY), &hit) == .success,
              var element = hit else { return nil }
        // The hit may be text inside the field; walk up to the field itself.
        for _ in 0..<3 where !isTypeable(element) {
            guard let parent: AXUIElement = value(element, kAXParentAttribute) else { return nil }
            element = parent
        }
        guard isTypeable(element) else { return nil }
        return value(element, kAXValueAttribute)
    }

    /// The contents of the app's focused text field, for a local check of a
    /// typing step. Nil when focus isn't a readable, non-password text field
    /// (a canvas, a grid, a custom editor): the caller can't know what was typed.
    static func focusedContents(app bundleIdentifier: String) -> String? {
        guard let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first else { return nil }
        let application = AXUIElementCreateApplication(running.processIdentifier)
        AXUIElementSetMessagingTimeout(application, 0.25)
        guard let focused: AXUIElement = value(application, kAXFocusedUIElementAttribute), isTypeable(focused) else { return nil }
        return value(focused, kAXValueAttribute)
    }

    /// Where typing will land in the app: the selected cell or item of the
    /// focused control, else the focused control itself. Nil when that is the
    /// whole window or grid (too large to point at usefully) or unreadable.
    static func focusFrame(app bundleIdentifier: String) -> CGRect? {
        guard let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first else { return nil }
        let application = AXUIElementCreateApplication(running.processIdentifier)
        AXUIElementSetMessagingTimeout(application, 0.25)
        guard let focused: AXUIElement = value(application, kAXFocusedUIElementAttribute) else { return nil }
        let selected: [AXUIElement] = value(focused, kAXSelectedCellsAttribute) ?? value(focused, kAXSelectedChildrenAttribute) ?? []
        let element = selected.first ?? focused
        guard let axFrame = AccessibilityTreeWalker.copyFrame(from: element).frame, axFrame.width > 0, axFrame.height > 0 else { return nil }
        let screen = CGDisplayBounds(CGMainDisplayID())
        guard axFrame.width * axFrame.height <= screen.width * screen.height * 0.25 else { return nil }
        return AccessibilityTreeWalker.convertAccessibilityFrameToAppKitFrame(axFrame, primaryDisplayHeightInPoints: screen.height)
    }

    /// What is left to type when the focused field already holds `contents`:
    /// nothing when it is exactly the text, the rest when it holds only the
    /// beginning of it (the owner started typing), else the whole text.
    static func remainder(of text: String, after contents: String?) -> String {
        guard let contents else { return text }
        let held = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        if held == text.trimmingCharacters(in: .whitespacesAndNewlines) { return "" }
        if !contents.isEmpty, text.hasPrefix(contents) { return String(text.dropFirst(contents.count)) }
        return text
    }

    /// Presses Return in the app's focused text field, after Go typed into it on
    /// a step the planner marked as needing Return. Only when that app is in front
    /// and its focused element is a typeable, non-password field.
    static func pressReturn(app bundleIdentifier: String) -> Bool {
        guard GoActiveApp.isActive(bundleIdentifier),
              let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first else { return false }
        let application = AXUIElementCreateApplication(running.processIdentifier)
        AXUIElementSetMessagingTimeout(application, 0.25)
        guard let focused: AXUIElement = value(application, kAXFocusedUIElementAttribute), isTypeable(focused) else { return false }
        let returnKey: CGKeyCode = 36
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: returnKey, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: returnKey, keyDown: false) else { return false }
        down.postToPid(running.processIdentifier)
        up.postToPid(running.processIdentifier)
        return true
    }

    /// True when the app's focused element is a password field, or its subrole
    /// cannot be read (then it might be one). Screenshots are skipped then.
    static func secureFieldFocused(app bundleIdentifier: String) -> Bool {
        guard let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first else { return false }
        let application = AXUIElementCreateApplication(running.processIdentifier)
        AXUIElementSetMessagingTimeout(application, 0.25)
        guard let focused: AXUIElement = value(application, kAXFocusedUIElementAttribute) else { return false }
        var subrole: AnyObject?
        let result = AXUIElementCopyAttributeValue(focused, kAXSubroleAttribute as CFString, &subrole)
        if result == .success { return (subrole as? String) == "AXSecureTextField" }
        return !(result == .noValue || result == .attributeUnsupported)
    }

    /// Does the owner's typing match the step? Case, spacing and surrounding
    /// punctuation are ignored.
    static func matches(_ contents: String?, typeText: String) -> Bool {
        func normalised(_ text: String) -> String {
            text.lowercased().components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
                .trimmingCharacters(in: .punctuationCharacters)
        }
        let wanted = normalised(typeText)
        guard let contents, !wanted.isEmpty else { return false }
        return normalised(contents).contains(wanted)
    }

    private static func isTypeable(_ element: AXUIElement) -> Bool {
        guard let role: String = value(element, kAXRoleAttribute), roles.contains(role) else { return false }
        // A subrole that cannot be read might be a password box: never treat it as typeable.
        var subrole: AnyObject?
        let result = AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole)
        if result == .success { return (subrole as? String) != "AXSecureTextField" }
        return result == .noValue || result == .attributeUnsupported
    }

    private static func label(of element: AXUIElement) -> String {
        var candidates: [String?] = [value(element, kAXTitleAttribute), value(element, kAXDescriptionAttribute),
                                     value(element, kAXPlaceholderValueAttribute)]
        if let titleElement: AXUIElement = value(element, kAXTitleUIElementAttribute) {
            candidates += [value(titleElement, kAXValueAttribute), value(titleElement, kAXTitleAttribute)]
        }
        for candidate in candidates {
            guard let text = candidate?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty, text.count <= 80,
                  UntrustedText(text).isPlausibleControlLabel else { continue }
            return text
        }
        return ""
    }

    private static func value<T>(_ element: AXUIElement, _ attribute: String) -> T? {
        var raw: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success else { return nil }
        return raw as? T
    }
}
