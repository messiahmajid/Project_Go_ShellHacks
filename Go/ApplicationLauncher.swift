//
//  ApplicationLauncher.swift
//  Go
//
//  The `launch` verb: resolve an installed app by identity, start it, and wait
//  until the app itself reports it is in front.
//

import AppKit
import ApplicationServices
import Foundation

nonisolated enum ApplicationLauncher {

    /// Generous against the slowest measured cold start (about 1.5 s).
    static let launchReadinessDeadlineInSeconds: TimeInterval = 5.0
    static let pollIntervalInMicroseconds: useconds_t = 100_000
    static let messagingTimeoutInSeconds: Float = 0.5

    /// Where a name may resolve. Never a path: a path could be a script.
    static var searchDirectories: [URL] {
        [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications/Utilities", isDirectory: true),
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Applications", isDirectory: true)
        ]
    }

    // MARK: - Resolution

    /// Every `<name>.app` in `directories`, exact and case-insensitive. More than
    /// one result is ambiguous, never first-wins.
    static func matchApplications(
        named name: String,
        in directories: [URL],
        listing: (URL) -> [String]
    ) -> [URL] {
        let wanted = name + ".app"
        return directories.flatMap { directory in
            listing(directory)
                .filter { $0.caseInsensitiveCompare(wanted) == .orderedSame }
                .map { directory.appendingPathComponent($0, isDirectory: true) }
        }
    }

    enum Resolution {
        case resolved(url: URL, bundleIdentifier: String)
        case notFound
        case ambiguous([URL])
    }

    /// Running apps matched by bundle id or exact name. A query matching two
    /// bundles is ambiguous.
    static func runningMatches(named query: String, among running: [(name: String?, bundleURL: URL?)]) -> [URL] {
        running.compactMap { entry in
            guard let name = entry.name, let url = entry.bundleURL,
                  name.caseInsensitiveCompare(query) == .orderedSame else { return nil }
            return url
        }
    }

    static func resolve(_ query: String) -> Resolution {
        var candidates = matchApplications(named: query, in: searchDirectories) {
            (try? FileManager.default.contentsOfDirectory(atPath: $0.path)) ?? []
        }
        if let byIdentifier = NSWorkspace.shared.urlForApplication(withBundleIdentifier: query) {
            candidates.append(byIdentifier)
        }
        // Running apps are included, so Finder (in CoreServices, which isn't
        // searched) can be launched by name.
        candidates += runningMatches(named: query, among: AccessibilityWindows.runningApplications().map {
            (name: $0.application.localizedName, bundleURL: $0.application.bundleURL)
        })
        var seen = Set<String>()
        let unique = candidates.filter { seen.insert($0.resolvingSymlinksInPath().path).inserted }

        guard !unique.isEmpty else { return .notFound }
        guard unique.count == 1, let url = unique.first else { return .ambiguous(unique) }
        // The kernel decides on the bundle's own identifier, never the query.
        guard url.pathExtension.caseInsensitiveCompare("app") == .orderedSame,
              let bundleIdentifier = Bundle(url: url)?.bundleIdentifier else {
            return .notFound
        }
        return .resolved(url: url, bundleIdentifier: bundleIdentifier)
    }

    // MARK: - Readiness

    /// One poll of the launched app, read from its own element (`AXFrontmost`).
    /// System-wide reads and `isFinishedLaunching` proved unreliable during launch.
    struct ReadinessSample: Equatable {
        var frontmost: Bool?
        var frontmostError: Int32?
        var window: Bool
        var windowError: Int32? = nil
    }

    enum LaunchStatus: String {
        case ready
        /// Came forward, but no window by the deadline (some apps are windowless).
        case frontmostNoWindow
        case notReady
    }

    /// An error means "not answering yet", never "no".
    static func isFrontmost(_ sample: ReadinessSample) -> Bool {
        sample.frontmostError == nil && sample.frontmost == true
    }

    /// nil means keep polling. A window without frontmost is still not ready.
    static func status(frontmostSeen: Bool, windowSeen: Bool, deadlinePassed: Bool) -> LaunchStatus? {
        if frontmostSeen, windowSeen { return .ready }
        guard deadlinePassed else { return nil }
        return frontmostSeen ? .frontmostNoWindow : .notReady
    }

    // MARK: - Perform

    /// Times are measured from the `openApplication` call.
    struct LaunchOutcome {
        /// Set when no process came back.
        var launchError: String?
        var processMilliseconds: Int?
        var frontmostMilliseconds: Int?
        var windowMilliseconds: Int?
        var lastFrontmostError: Int32?
        var lastWindowError: Int32?
        var status: LaunchStatus = .notReady
        var readinessPolls = 0
    }

    private final class LaunchBox: @unchecked Sendable {
        var application: NSRunningApplication?
        var error: Error?
    }

    /// Blocks the request queue for up to the deadline. The completion handler
    /// runs on a background queue, and a hard deadline bounds the wait anyway.
    static func launchAndWait(_ url: URL) -> LaunchOutcome {
        let startedAt = Date()
        let deadline = startedAt.addingTimeInterval(launchReadinessDeadlineInSeconds)
        func elapsed() -> Int { Int(Date().timeIntervalSince(startedAt) * 1000) }

        var outcome = LaunchOutcome()
        let box = LaunchBox()
        let semaphore = DispatchSemaphore(value: 0)
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true

        // Also called for a running app, which activates it.
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { application, error in
            box.application = application
            box.error = error
            semaphore.signal()
        }

        guard semaphore.wait(timeout: .now() + launchReadinessDeadlineInSeconds) == .success else {
            outcome.launchError = "openApplication did not call back within \(launchReadinessDeadlineInSeconds) s"
            return outcome
        }
        guard let application = box.application else {
            outcome.launchError = box.error.map { String(describing: $0) }
                ?? "openApplication returned neither an application nor an error"
            return outcome
        }
        outcome.processMilliseconds = elapsed()

        let applicationElement = AXUIElementCreateApplication(application.processIdentifier)
        AXUIElementSetMessagingTimeout(applicationElement, messagingTimeoutInSeconds)

        while true {
            outcome.readinessPolls += 1
            let sample = readSample(
                applicationElement,
                readFrontmost: outcome.frontmostMilliseconds == nil,
                readWindow: outcome.windowMilliseconds == nil
            )
            if let code = sample.frontmostError { outcome.lastFrontmostError = code }
            if let code = sample.windowError { outcome.lastWindowError = code }
            if outcome.frontmostMilliseconds == nil, isFrontmost(sample) { outcome.frontmostMilliseconds = elapsed() }
            if outcome.windowMilliseconds == nil, sample.window { outcome.windowMilliseconds = elapsed() }

            if let status = status(
                frontmostSeen: outcome.frontmostMilliseconds != nil,
                windowSeen: outcome.windowMilliseconds != nil,
                deadlinePassed: Date() >= deadline
            ) {
                outcome.status = status
                return outcome
            }
            usleep(pollIntervalInMicroseconds)
        }
    }

    /// Only the reads still needed; each can cost a full timeout.
    private static func readSample(
        _ element: AXUIElement,
        readFrontmost: Bool,
        readWindow: Bool
    ) -> ReadinessSample {
        var sample = ReadinessSample(frontmost: nil, frontmostError: nil, window: false)

        if readFrontmost {
            var value: AnyObject?
            let error = AXUIElementCopyAttributeValue(element, kAXFrontmostAttribute as CFString, &value)
            if error == .success { sample.frontmost = value as? Bool } else { sample.frontmostError = error.rawValue }
        }

        if readWindow {
            var value: AnyObject?
            let error = AXUIElementCopyAttributeValue(element, kAXFocusedWindowAttribute as CFString, &value)
            if error == .success, value != nil {
                sample.window = true
            } else {
                sample.windowError = error.rawValue
                if error != .cannotComplete {
                    var windows: AnyObject?
                    if AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &windows) == .success,
                       let list = windows as? [AXUIElement], !list.isEmpty {
                        sample.window = true
                    }
                }
            }
        }
        return sample
    }
}
