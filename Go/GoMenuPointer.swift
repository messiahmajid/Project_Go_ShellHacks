import AppKit
import ApplicationServices

/// Menu-bar items are not part of a window snapshot, so menu steps are grounded
/// here, read-only. It returns the deepest visible element along the path: the
/// top-level menu while it is closed, then the item inside once the owner opens it.
nonisolated enum GoMenuPointer {
    static func frame(app bundleIdentifier: String, path: [String]) -> CGRect? {
        target(app: bundleIdentifier, path: path)?.rect
    }

    /// `isLeaf` is true when the pointer reached the item that performs the step.
    static func target(app bundleIdentifier: String, path: [String]) -> (rect: CGRect, isLeaf: Bool)? {
        guard !path.isEmpty,
              let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first else { return nil }
        let application = AXUIElementCreateApplication(running.processIdentifier)
        AXUIElementSetMessagingTimeout(application, 0.5)
        guard let menuBar: AXUIElement = value(application, kAXMenuBarAttribute) else { return nil }
        let primaryHeight = CGDisplayBounds(CGMainDisplayID()).height
        var container = menuBar
        var deepest: CGRect?
        var depth = 0
        for title in path {
            let items: [AXUIElement] = value(container, kAXChildrenAttribute) ?? []
            guard let item = items.first(where: { (value($0, kAXTitleAttribute) as String?)?
                    .trimmingCharacters(in: .whitespaces) == title.trimmingCharacters(in: .whitespaces) }),
                  let axFrame = AccessibilityTreeWalker.copyFrame(from: item).frame,
                  axFrame.width > 0, axFrame.height > 0, axFrame.origin.x.isFinite, axFrame.origin.y.isFinite else { break }
            deepest = AccessibilityTreeWalker.convertAccessibilityFrameToAppKitFrame(axFrame, primaryDisplayHeightInPoints: primaryHeight)
            depth += 1
            // Descend only into a menu that is open now; closed menus have no trustworthy frames.
            guard (value(item, kAXSelectedAttribute) as Bool?) == true,
                  let menu = (value(item, kAXChildrenAttribute) as [AXUIElement]?)?.first(where: {
                      (value($0, kAXRoleAttribute) as String?) == kAXMenuRole }) else { break }
            container = menu
        }
        return deepest.map { ($0, depth == path.count) }
    }

    /// The Dock icon for an app, if it is in the Dock: where to point for "open X".
    static func dockIcon(named name: String) -> CGRect? {
        let wanted = name.lowercased()
        return GoSystemControls.dockItems().first { $0.name.lowercased() == wanted }?.frame
    }

    private static func value<T>(_ element: AXUIElement, _ attribute: String) -> T? {
        var raw: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success else { return nil }
        return raw as? T
    }
}
