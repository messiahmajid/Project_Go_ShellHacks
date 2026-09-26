import AppKit
import ApplicationServices

/// Pointer clicks for targets that exist only visually (icon-only or
/// custom-drawn controls, the Dock, menu bar extras). Used only when the owner
/// asked Go to act, after `GoStepExecutor.screenTargetRefusal` screening.
nonisolated enum GoScreenClick {
    /// Names and password status of the Accessibility element under a point,
    /// when the app exposes one. Screening input only; never logged or sent.
    static func describeElement(at point: CGPoint) -> (names: [String], isSecure: Bool) {
        let primaryHeight = CGDisplayBounds(CGMainDisplayID()).height
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, 0.25)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(primaryHeight - point.y), &hit) == .success,
              let element = hit else { return ([], false) }
        func string(_ attribute: String) -> String? {
            var raw: AnyObject?
            guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success else { return nil }
            return raw as? String
        }
        let names = [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute].compactMap { string($0) }
        return (names, string(kAXSubroleAttribute) == "AXSecureTextField")
    }

    /// The exact frame of the control under the centre of a screenshot box, so
    /// a highlight covers the real item rather than the planner's estimate.
    /// Labels and images inside a control are walked up to the control. Nil when
    /// nothing answers there, it is Go's own overlay, or the frame is implausibly
    /// different in size from the box (a whole window or panel).
    static func elementFrame(near rect: CGRect) -> CGRect? {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return nil }
        let primaryHeight = CGDisplayBounds(CGMainDisplayID()).height
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, 0.25)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(systemWide, Float(rect.midX), Float(primaryHeight - rect.midY), &hit) == .success,
              var element = hit else { return nil }
        var pid: pid_t = 0
        if AXUIElementGetPid(element, &pid) == .success, pid == getpid() { return nil }
        func role(_ element: AXUIElement) -> String? {
            var raw: AnyObject?
            guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &raw) == .success else { return nil }
            return raw as? String
        }
        // Text and images are parts of a control, not the control.
        let parts: Set<String> = ["AXStaticText", "AXImage", "AXUnknown"]
        for _ in 0..<3 where parts.contains(role(element) ?? "AXUnknown") {
            var parent: AnyObject?
            guard AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &parent) == .success,
                  let parent, CFGetTypeID(parent) == AXUIElementGetTypeID() else { break }
            element = parent as! AXUIElement
        }
        guard let axFrame = AccessibilityTreeWalker.copyFrame(from: element).frame else { return nil }
        let frame = AccessibilityTreeWalker.convertAccessibilityFrameToAppKitFrame(axFrame, primaryDisplayHeightInPoints: primaryHeight)
        return plausibleRefinement(frame, of: rect) ? frame : nil
    }

    /// The element's frame holds the box's centre and is of a comparable size.
    static func plausibleRefinement(_ frame: CGRect, of rect: CGRect) -> Bool {
        let boxArea = rect.width * rect.height, frameArea = frame.width * frame.height
        guard boxArea > 0, frameArea > 0, frame.contains(CGPoint(x: rect.midX, y: rect.midY)) else { return false }
        return frameArea <= boxArea * 8 && frameArea >= boxArea / 8
    }

    /// What sits under a point (role and first name), to notice when a fixed-position
    /// target has been scrolled away or replaced. Nil when nothing answers there.
    static func fingerprint(at point: CGPoint) -> String? {
        let primaryHeight = CGDisplayBounds(CGMainDisplayID()).height
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, 0.2)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(primaryHeight - point.y), &hit) == .success,
              let element = hit else { return nil }
        // Go's own overlay (cursor, highlight) is never the thing being tracked.
        var pid: pid_t = 0
        if AXUIElementGetPid(element, &pid) == .success, pid == getpid() { return nil }
        func string(_ attribute: String) -> String? {
            var raw: AnyObject?
            guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success else { return nil }
            return raw as? String
        }
        let role = string(kAXRoleAttribute) ?? "?"
        let name = [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute].lazy.compactMap { string($0) }.first ?? ""
        return role + "|" + name
    }

    /// Scrolls the app's focused window by about a screenful, with the pointer
    /// briefly over it (scroll events go to the window under the pointer), then
    /// puts the owner's pointer back. Only for the app that is in front.
    static func scroll(_ direction: String, inFrontWindowOf bundleIdentifier: String) -> Bool {
        guard GoActiveApp.isActive(bundleIdentifier),
              let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first else { return false }
        let application = AXUIElementCreateApplication(running.processIdentifier)
        AXUIElementSetMessagingTimeout(application, 0.25)
        var raw: AnyObject?
        guard AXUIElementCopyAttributeValue(application, kAXFocusedWindowAttribute as CFString, &raw) == .success,
              let window = raw, CFGetTypeID(window) == AXUIElementGetTypeID(),
              let frame = AccessibilityTreeWalker.copyFrame(from: window as! AXUIElement).frame else { return false }
        let target = CGPoint(x: frame.midX, y: frame.midY)          // Accessibility coordinates: top-left origin
        let primaryHeight = CGDisplayBounds(CGMainDisplayID()).height
        let original = NSEvent.mouseLocation
        CGWarpMouseCursorPosition(target)
        let lines: Int32 = direction == "up" ? 12 : -12
        guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: lines, wheel2: 0, wheel3: 0) else { return false }
        event.location = target
        event.post(tap: .cghidEventTap)
        usleep(80_000)
        CGWarpMouseCursorPosition(CGPoint(x: original.x, y: primaryHeight - original.y))
        return true
    }

    /// A real click at a global AppKit point. With `restoringPointer`, the owner's
    /// pointer jumps back afterwards; do-it-for-me leaves it where Go clicked,
    /// under Go's cursor, so it doesn't flick back and forth on every step.
    static func click(at point: CGPoint, count: Int, restoringPointer: Bool = true) -> Bool {
        let primaryHeight = CGDisplayBounds(CGMainDisplayID()).height
        let target = CGPoint(x: point.x, y: primaryHeight - point.y)
        let original = NSEvent.mouseLocation
        let restore = CGPoint(x: original.x, y: primaryHeight - original.y)
        guard let move = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: target, mouseButton: .left) else { return false }
        move.post(tap: .cghidEventTap)
        for index in 1...max(1, count) {
            guard let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: target, mouseButton: .left),
                  let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: target, mouseButton: .left) else { return false }
            down.setIntegerValueField(.mouseEventClickState, value: Int64(index))
            up.setIntegerValueField(.mouseEventClickState, value: Int64(index))
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
        }
        usleep(60_000)
        if restoringPointer { CGWarpMouseCursorPosition(restore) }
        return true
    }
}

/// Apps (this session) whose controls ignored an Accessibility press but
/// responded to a real click; their later steps are clicked after a kernel dry run.
@MainActor
enum GoPointerApps {
    private static var apps: Set<String> = []
    static func contains(_ app: String) -> Bool { apps.contains(app) }
    static func insert(_ app: String) { apps.insert(app) }
}
