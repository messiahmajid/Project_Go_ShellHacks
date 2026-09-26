import AppKit
import ApplicationServices

/// A control outside the current app that the owner can still click: a
/// menu-bar status icon (Control Center, Wi-Fi, the clock, a third-party
/// icon) or a Dock item. None of these are in the app's own accessibility
/// tree, so they are listed separately with their real names and exact frames.
nonisolated struct GoSystemControl: Codable, Equatable, Sendable {
    let id: String
    /// "menuBarIcon" or "dockItem".
    let kind: String
    let name: String
    let frame: GoFrame
}

nonisolated enum GoSystemControls {
    /// Reading every process's status icons takes about a second, so the list
    /// is cached briefly and refreshed in the background.
    static let menuBarCacheSeconds: TimeInterval = 30

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cachedMenuBar: (at: Date, items: [(name: String, frame: CGRect)])?
    nonisolated(unsafe) private static var refreshing = false

    /// Status icons and Dock items, with IDs "s0", "s1", …. Uses the cached
    /// status icons (starting a refresh when stale) and reads the Dock fresh.
    static func current() -> [GoSystemControl] {
        // Unit tests never read the machine running them.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return [] }
        let icons = menuBarIcons()
        let dock = dockItems()
        return make(menuBar: icons, dock: dock)
    }

    /// Starts reading the status icons in the background, so the first plan has them.
    static func prefetch() {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        _ = menuBarIcons()
    }

    /// Builds the list: plausible, unique-enough labels only, capped in size.
    static func make(menuBar: [(name: String, frame: CGRect)], dock: [(name: String, frame: CGRect)]) -> [GoSystemControl] {
        var result: [GoSystemControl] = []
        func add(_ kind: String, _ entries: [(name: String, frame: CGRect)]) {
            for entry in entries where result.count < 60 {
                let name = entry.name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard UntrustedText(name).isPlausibleControlLabel, name.count <= 60,
                      entry.frame.width > 0, entry.frame.height > 0 else { continue }
                result.append(GoSystemControl(id: "s\(result.count)", kind: kind, name: name, frame: GoFrame(entry.frame)))
            }
        }
        add("menuBarIcon", menuBar)
        add("dockItem", dock)
        return result
    }

    private static func menuBarIcons() -> [(name: String, frame: CGRect)] {
        lock.lock()
        let cached = cachedMenuBar
        let stale = cached.map { Date().timeIntervalSince($0.at) > menuBarCacheSeconds } ?? true
        let startRefresh = stale && !refreshing
        if startRefresh { refreshing = true }
        lock.unlock()
        if startRefresh {
            DispatchQueue.global(qos: .utility).async {
                let items = AccessibilityStatusItems.readAll().items.compactMap { item -> (String, CGRect)? in
                    let descriptor = item.descriptor
                    let name = descriptor.elementDescription?.raw ?? descriptor.title?.raw ?? descriptor.ownerName
                    guard let name else { return nil }
                    return (name, descriptor.frameInAppKitCoordinates)
                }
                lock.lock()
                cachedMenuBar = (Date(), items.map { (name: $0.0, frame: $0.1) })
                refreshing = false
                lock.unlock()
            }
        }
        return cached?.items ?? []
    }

    /// Every item in the Dock with a title and a frame.
    static func dockItems() -> [(name: String, frame: CGRect)] {
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { return [] }
        let application = AXUIElementCreateApplication(dock.processIdentifier)
        AXUIElementSetMessagingTimeout(application, 0.25)
        let primaryHeight = CGDisplayBounds(CGMainDisplayID()).height
        var items: [(name: String, frame: CGRect)] = []
        for list in (value(application, kAXChildrenAttribute) as [AXUIElement]?) ?? [] {
            for item in (value(list, kAXChildrenAttribute) as [AXUIElement]?) ?? [] {
                guard let title: String = value(item, kAXTitleAttribute), !title.isEmpty,
                      let frame = AccessibilityTreeWalker.copyFrame(from: item).frame, frame.width > 0, frame.height > 0 else { continue }
                items.append((title, AccessibilityTreeWalker.convertAccessibilityFrameToAppKitFrame(frame, primaryDisplayHeightInPoints: primaryHeight)))
            }
        }
        return items
    }

    private static func value<T>(_ element: AXUIElement, _ attribute: String) -> T? {
        var raw: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success else { return nil }
        return raw as? T
    }
}
