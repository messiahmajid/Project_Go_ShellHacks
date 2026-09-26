import AppKit

/// The app the owner is working in right now, as Accessibility sees it.
///
/// This differs from `NSWorkspace.frontmostApplication` for system panels that
/// take focus without becoming the frontmost app: Control Center, menu-bar
/// status menus, Notification Center, Spotlight, and popovers from menu-bar
/// apps. Guidance, click checks and typing all use this, so a step inside one
/// of those panels is shown and followed like any other. It is also what the
/// harness reads, so both sides agree on which app a step belongs to.
nonisolated enum GoActiveApp {
    static var bundleIdentifier: String? {
        choose(focused: AccessibilityTreeWalker.focusedApplication()?.bundleIdentifier,
               frontmost: NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
               own: Bundle.main.bundleIdentifier)
    }

    /// Accessibility's focused app wins; Go's own panel holding focus means the
    /// owner still means the app behind it.
    static func choose(focused: String?, frontmost: String?, own: String?) -> String? {
        if let focused, focused != own { return focused }
        return frontmost == own ? nil : frontmost
    }

    static func isActive(_ bundleIdentifier: String) -> Bool {
        self.bundleIdentifier == bundleIdentifier
    }
}
