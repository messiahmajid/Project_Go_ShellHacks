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

/// A cheap sign that the app in front changed, for "did that click or action
/// do anything yet?": the app, its windows, the focused window's title and
/// top-level parts (a sheet, dialog or panel appearing), the focused control
/// and its selected item (a cell or row). A handful of Accessibility reads
/// instead of a walk of the whole interface, which in a large document takes
/// about a second. Only compared locally; nothing is kept or logged.
nonisolated enum GoScreenPulse {
    /// `structureOnly`: just the app, its windows and the window's top-level parts
    /// (something opened or closed, a new page), leaving out focus and selection.
    static func current(structureOnly: Bool = false) -> Int {
        // Unit tests never read the machine running them.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return 0 }
        var hasher = Hasher()
        guard let bundle = GoActiveApp.bundleIdentifier,
              let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first else { return 0 }
        hasher.combine(bundle)
        let app = AXUIElementCreateApplication(running.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 0.1)
        func read<T>(_ element: AXUIElement, _ attribute: String) -> T? {
            var raw: AnyObject?
            guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success else { return nil }
            return raw as? T
        }
        func describe(_ element: AXUIElement) {
            hasher.combine(read(element, kAXRoleAttribute) as String?)
            hasher.combine(read(element, kAXTitleAttribute) as String?)
            hasher.combine(read(element, kAXDescriptionAttribute) as String?)
        }
        hasher.combine((read(app, kAXWindowsAttribute) as [AXUIElement]?)?.count ?? -1)
        if let window: AXUIElement = read(app, kAXFocusedWindowAttribute) {
            hasher.combine(read(window, kAXTitleAttribute) as String?)
            let parts: [AXUIElement] = read(window, kAXChildrenAttribute) ?? []
            hasher.combine(parts.count)
            for part in parts.prefix(40) { hasher.combine(read(part, kAXRoleAttribute) as String?) }
        }
        if !structureOnly, let focused: AXUIElement = read(app, kAXFocusedUIElementAttribute) {
            describe(focused)
            let selected: [AXUIElement] = read(focused, kAXSelectedCellsAttribute)
                ?? read(focused, kAXSelectedChildrenAttribute) ?? read(focused, kAXSelectedRowsAttribute) ?? []
            hasher.combine(selected.count)
            if let first = selected.first { describe(first) }
        }
        return hasher.finalize()
    }
}
