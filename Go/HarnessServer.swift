//
//  HarnessServer.swift
//  Go
//
//  The harness every Go action goes through: read the app, resolve the target,
//  ask the safety kernel, act, verify, and write an audit line. Go calls it
//  in-process; `--harness` also exposes it on a Unix socket (mode 0600) for tests.
//

import AppKit
import ApplicationServices
import Darwin
import Foundation

// MARK: - Wire types

/// One request line. Fields past `verb` are optional; a missing one is a
/// structured refusal, never a crash.
nonisolated struct HarnessRawRequest: Decodable {
    let id: String?
    let verb: String
    let title: String?
    let role: String?
    let withinNamed: String?
    let nearPoint: HarnessPoint?
    let dryRun: Bool?
    let confirmed: Bool?
    /// A confirmation ticket the user already answered in Go's panel.
    let ticket: String?

    /// menu / menus: the path down the menu bar, e.g. ["File", "New Folder"].
    let path: [String]?
    /// menu: a status icon instead of a path.
    let statusItem: String?

    /// windows / focus: the app by bundle id or name; absent means frontmost.
    let app: String?

    /// Refuse unless the frontmost app is this one.
    let expectApp: String?

    let text: String?
    let mode: String?
    /// `"focused"`, or absent to resolve by name.
    let target: String?
    let thenConfirm: Bool?

    /// look: force a rung of the escalation ladder.
    let tier: String?
    /// On `notFound` / `ambiguous`, include a picture as well as the offer of one.
    let escalate: Bool?

    /// highlight: how long the outline stays, and its caption.
    let seconds: Double?
    let label: String?
}

nonisolated struct HarnessPoint: Decodable {
    let x: Double
    let y: Double
    var cgPoint: CGPoint { CGPoint(x: x, y: y) }
}

nonisolated enum HarnessVerb: String, CaseIterable {
    case ping
    case snapshot
    case press
    case select
    case type
    case open

    /// Press a menu item by its path down the menu bar.
    case menu
    /// List the menu bar's items. Read-only, and separate because it is slow.
    case menus

    /// An app's windows, and the running apps.
    case windows
    /// Bring a different window forward.
    case focus

    /// A small capture plus the candidates inside it. Read-only.
    case look

    /// Start or activate an installed app and wait until it is in front.
    case launch

    /// Every status icon on the right of the menu bar. Read-only.
    case status

    /// Outline an element on Go's overlay. Read-only.
    case highlight

    /// Whether this verb can change anything. The kill switch stops these and
    /// leaves the read-only verbs working.
    var isMutating: Bool {
        switch self {
        case .ping, .snapshot, .menus, .windows, .look, .status, .highlight: return false
        case .press, .select, .type, .open, .menu, .focus, .launch: return true
        }
    }

    var elementAction: ElementAction? {
        switch self {
        case .press: return .press
        case .select: return .select
        case .type: return .type
        case .open: return .open
        // These verbs do not resolve an element name in the focused window:
        // menu uses a path, focus a window, look only reads, launch an app, and
        // highlight performs nothing.
        case .ping, .snapshot, .menu, .menus, .windows, .focus, .look, .launch, .status, .highlight: return nil
        }
    }
}

/// A request refused before it ran, as opposed to one refused on policy.
nonisolated enum HarnessRequestError: Error, Equatable {
    case malformedJSON(String)
    case unknownVerb(String)
    case missingField(String)

    /// A present field with an unrecognised value; near-misses are never guessed.
    case invalidField(field: String, value: String)

    var code: String {
        switch self {
        case .malformedJSON: return "malformedJSON"
        case .unknownVerb: return "unknownVerb"
        case .missingField: return "missingField"
        case .invalidField: return "invalidField"
        }
    }

    var message: String {
        switch self {
        case .malformedJSON(let detail):
            return "could not parse the line as JSON: \(detail)"
        case .unknownVerb(let verb):
            // Never guess a near-miss verb.
            return "unknown verb \"\(verb)\" — known verbs: \(HarnessVerb.allCases.map(\.rawValue).joined(separator: ", "))"
        case .missingField(let field):
            return "missing required field \"\(field)\""
        case .invalidField(let field, let value):
            return "field \"\(field)\" does not accept \"\(value)\""
        }
    }
}

/// A decoded, validated request.
nonisolated struct HarnessRequest: Equatable {
    let id: String
    let verb: HarnessVerb
    let title: String
    let role: String?
    let withinNamed: String?
    let nearPoint: CGPoint?
    let requestedDryRun: Bool?
    let confirmed: Bool

    var text: String = ""
    var mode: TypeMode = .insert
    /// Aim at the focused element instead of resolving a name.
    var aimAtFocus: Bool = false
    /// highlight: the window itself (some windows have no title to name).
    var aimAtWindow: Bool = false
    var thenConfirm: Bool = false

    var ticket: String? = nil

    var path: [String] = []
    var statusItem: String? = nil

    var app: String? = nil

    /// nil means act in whatever is in front.
    var expectApp: String? = nil

    var tier: EscalationLadder.Tier? = nil
    /// Acting verbs: whether a failed resolution should include a capture.
    var escalate: Bool = false

    var highlightSeconds: Double = HarnessPolicy.defaultHighlightSeconds
    var label: String? = nil
}

// MARK: - Pure decision logic

nonisolated enum HarnessPolicy {

    static func decode(line: String) -> Result<HarnessRequest, HarnessRequestError> {
        guard let data = line.data(using: .utf8) else {
            return .failure(.malformedJSON("not valid UTF-8"))
        }

        let raw: HarnessRawRequest
        do {
            raw = try JSONDecoder().decode(HarnessRawRequest.self, from: data)
        } catch let DecodingError.keyNotFound(key, _) {
            return .failure(.missingField(key.stringValue))
        } catch {
            return .failure(.malformedJSON(String(describing: error).prefix(200).description))
        }

        guard let verb = HarnessVerb(rawValue: raw.verb) else {
            return .failure(.unknownVerb(raw.verb))
        }

        // `target` takes only "focused"; anything else is a typo, not a name.
        var aimAtFocus = false
        var aimAtWindow = false
        if let target = raw.target {
            switch target {
            case "focused": aimAtFocus = true
            // Outline only: acting verbs never aim at a whole window.
            case "window" where verb == .highlight: aimAtWindow = true
            default: return .failure(.invalidField(field: "target", value: target))
            }
        }

        if verb.elementAction != nil || verb == .highlight, !aimAtFocus, !aimAtWindow, (raw.title ?? "").isEmpty {
            return .failure(.missingField("title"))
        }

        let path = raw.path ?? []
        var statusItem: String?
        if verb == .menu {
            if let requested = raw.statusItem {
                // Empty is a typo, and a path as well would be two targets.
                guard !requested.isEmpty, path.isEmpty else {
                    return .failure(.invalidField(field: "statusItem", value: requested))
                }
                statusItem = requested
            } else if path.isEmpty {
                return .failure(.missingField("path"))
            }
        }

        // focus needs an app, a title, or both.
        if verb == .focus, (raw.app ?? "").isEmpty, (raw.title ?? "").isEmpty {
            return .failure(.missingField("app"))
        }

        // launch names an installed app; a path could be a script, so it is refused.
        if verb == .launch {
            guard let app = raw.app, !app.isEmpty else { return .failure(.missingField("app")) }
            guard !app.contains("/") else { return .failure(.invalidField(field: "app", value: app)) }
        }

        // A typo'd or "none" tier is refused rather than ignored.
        var tier: EscalationLadder.Tier?
        if let requestedTier = raw.tier {
            guard let parsed = EscalationLadder.Tier(rawValue: requestedTier), parsed != .none else {
                return .failure(.invalidField(field: "tier", value: requestedTier))
            }
            tier = parsed
        }

        // An empty expectation is refused, not read as "none".
        if raw.expectApp?.isEmpty == true {
            return .failure(.invalidField(field: "expectApp", value: ""))
        }
        // Status items span every process, so there is no app to check.
        if verb == .status, let expectApp = raw.expectApp {
            return .failure(.invalidField(field: "expectApp", value: expectApp))
        }
        if raw.ticket?.isEmpty == true {
            return .failure(.invalidField(field: "ticket", value: ""))
        }

        // A caption is shown on screen, so it must be a plausible label.
        if let label = raw.label, !UntrustedText(label).isPlausibleControlLabel {
            return .failure(.invalidField(field: "label", value: UntrustedText(label).forDisplay))
        }

        var mode = TypeMode.insert
        if verb == .type {
            guard !(raw.text ?? "").isEmpty else {
                return .failure(.missingField("text"))
            }
            if let requestedMode = raw.mode {
                guard let parsed = TypeMode(rawValue: requestedMode) else {
                    return .failure(.invalidField(field: "mode", value: requestedMode))
                }
                mode = parsed
            }
        }

        return .success(HarnessRequest(
            id: raw.id ?? "",
            verb: verb,
            // For a menu, the path is the target.
            title: (verb == .menu || verb == .menus) && !path.isEmpty
                ? path.joined(separator: " > ")
                : (statusItem ?? raw.title ?? ""),
            role: raw.role,
            withinNamed: raw.withinNamed,
            nearPoint: raw.nearPoint?.cgPoint,
            requestedDryRun: raw.dryRun,
            confirmed: raw.confirmed ?? false,
            text: raw.text ?? "",
            mode: mode,
            aimAtFocus: aimAtFocus,
            aimAtWindow: aimAtWindow,
            thenConfirm: raw.thenConfirm ?? false,
            ticket: raw.ticket,
            path: path,
            statusItem: statusItem,
            app: (raw.app?.isEmpty == false) ? raw.app : nil,
            expectApp: raw.expectApp,
            tier: tier,
            escalate: raw.escalate ?? false,
            highlightSeconds: clampedHighlightSeconds(raw.seconds),
            label: raw.label
        ))
    }

    static let defaultHighlightSeconds = 2.0

    /// 0.5-10 s, default 2.
    static func clampedHighlightSeconds(_ requested: Double?) -> Double {
        min(max(requested ?? defaultHighlightSeconds, 0.5), 10)
    }

    /// Whether the app a verb read is the one the caller expected. Exact,
    /// case-insensitive; anything fuzzier would guess which app to act in.
    static func appMatches(expected: String, bundleIdentifier: String?, name: String?) -> Bool {
        [bundleIdentifier, name].contains { $0?.caseInsensitiveCompare(expected) == .orderedSame }
    }

    /// A request may turn a dry run on, never off.
    static func effectiveDryRun(requested: Bool?, globalDefault: Bool) -> Bool {
        globalDefault || (requested ?? false)
    }

    static let killSwitchReason =
        "harness kill switch is present (HARNESS_DISABLED) — mutating verbs are refused; ping and snapshot still work"

    /// nil when the verb may proceed.
    static func killSwitchRefusal(verb: HarnessVerb, killSwitchPresent: Bool) -> String? {
        (killSwitchPresent && verb.isMutating) ? killSwitchReason : nil
    }

    /// Only `.allow` runs without a person. A question becomes a ticket the user
    /// answers in Go's panel; a caller's `"confirmed": true` is recorded, not believed.
    static func executableWithoutAHuman(_ decision: SafetyDecision) -> Bool {
        if case .allow = decision { return true }
        return false
    }

    static func describe(_ decision: SafetyDecision) -> (decision: String, reason: String?) {
        switch decision {
        case .allow: return ("allow", nil)
        case .requireConfirmation(let reason, _): return ("requireConfirmation", reason)
        case .refuse(let reason): return ("refuse", reason)
        }
    }

    /// Caps an audit target's length, keeping its true length.
    static func cappedAuditTarget(_ target: String) -> String {
        guard target.count > UntrustedText.maximumDisplayLength else { return target }
        return String(target.prefix(UntrustedText.maximumDisplayLength)) + "… (\(target.count) chars)"
    }

    static let auditTimestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    /// One JSON audit line per request, so a title with a newline cannot forge a
    /// second record. `session` separates runs that share the file.
    static func auditLine(
        at timestamp: Date,
        id: String,
        verb: String,
        target: String?,
        app: String?,
        session: String,
        dryRun: Bool,
        confirmed: Bool,
        kernel: String,
        outcome: String,
        milliseconds: Int,
        frontmostSource: String? = nil,
        frontmostSystemWideError: Int32? = nil,
        /// Who lifted a confirmation: `caller`, `owner`, `approvalRule` or `trustedMode`.
        confirmedBy: String? = nil,
        phases: [String: Any] = [:]
    ) -> String {
        var fields: [String: Any] = [
            "timestamp": auditTimestampFormatter.string(from: timestamp),
            "id": id,
            "verb": verb,
            "target": target.map(cappedAuditTarget) ?? NSNull(),
            "app": app ?? NSNull(),
            "session": session,
            "dryRun": dryRun,
            "confirmed": confirmed,
            "kernel": kernel,
            "outcome": outcome,
            "ms": milliseconds
        ]
        if let frontmostSource { fields["frontmostSource"] = frontmostSource }
        if let frontmostSystemWideError { fields["frontmostSystemWideError"] = Int(frontmostSystemWideError) }
        if let confirmedBy { fields["confirmedBy"] = confirmedBy }
        fields.merge(phases) { existing, _ in existing }
        guard let data = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return "{\"timestamp\":\"\(auditTimestampFormatter.string(from: timestamp))\",\"outcome\":\"auditEncodingFailed\"}"
        }
        return text
    }
}

// MARK: - Observability
// //
// A healthy request costs one array append; files are written only on an anomaly.

/// Keeps the last N items.
nonisolated struct RingBuffer<Element> {
    let capacity: Int
    private(set) var elements: [Element] = []

    init(capacity: Int) {
        self.capacity = capacity
    }

    mutating func append(_ element: Element) {
        elements.append(element)
        if elements.count > capacity {
            elements.removeFirst(elements.count - capacity)
        }
    }
}

/// The anomalies worth a diagnostic dump.
nonisolated enum HarnessAnomaly: String, Equatable, CaseIterable {
    /// The kernel allowed it and the call succeeded, but nothing changed.
    case notObservedAfterAllow = "verification notObserved after the kernel allowed"

    /// An error that is not an ordinary refusal.
    case unexpectedError = "response error is not an ordinary refusal"

    /// A refusal on security grounds (secure field, implausible label).
    case securityRefusal = "the kernel refused on a security ground"

    /// The per-app policy file exists but cannot be parsed.
    case policyUnreadable = "the harness policy file is unreadable or malformed"

    /// The walk took over 3x the recent median for this app.
    case walkFarSlowerThanRecentMedian = "walk took more than 3x the median of recent walks"
}

nonisolated enum HarnessObservability {

    /// Refusals that mean the harness is working normally. `kernelRefused` is
    /// absent: a hard refusal is when the recent requests are worth keeping.
    static let ordinaryRefusalCodes: Set<String> = [
        "killSwitch", "confirmationRequired", "notFound", "ambiguous",
        // Ticket re-asks are the normal flow. Invalid, stale or flooded tickets stay
        // out: they are what an attempt to trick the card looks like.
        "confirmationPending", "confirmationDenied", "confirmationExpired",
        "dryRun", "unknownVerb", "malformedJSON", "missingField", "invalidField",
        // Policy refusals are logged; only security refusals get a dump (see `kernelReason`).
        "kernelRefused",
        "policyRefused",
        // Menu-bar agents and system panels (Control Center) have no menu bar.
        "noMenuBar",
        // An app with no ordinary window (Finder's desktop) cannot be captured alone.
        "applicationNotCapturable",
        "screenIsLocked",
        "targetNotOnScreen"
        // `targetIsHarnessItself` stays out: it is rare and worth seeing.
    ]

    /// Fewer samples than this and the median is noise.
    static let minimumWalkSamples = 5
    static let slowWalkMultiplier = 3

    static func median(of values: [Int]) -> Int? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }

    /// nil when nothing is wrong.
    static func anomaly(
        kernelDecision: String?,
        kernelReason: String? = nil,
        verificationStatus: String?,
        errorCode: String?,
        walkMilliseconds: Int?,
        recentWalkMilliseconds: [Int]
    ) -> HarnessAnomaly? {
        if verificationStatus == "notObserved", kernelDecision == "allow" {
            return .notObservedAfterAllow
        }
        if let kernelReason, ActionSafetyKernel.isSecurityRefusal(reason: kernelReason) {
            return .securityRefusal
        }
        if errorCode == "policyUnreadable" {
            return .policyUnreadable
        }
        if let errorCode, !ordinaryRefusalCodes.contains(errorCode) {
            return .unexpectedError
        }
        if let walkMilliseconds,
           recentWalkMilliseconds.count >= minimumWalkSamples,
           let median = median(of: recentWalkMilliseconds),
           median > 0,
           walkMilliseconds > median * slowWalkMultiplier {
            return .walkFarSlowerThanRecentMedian
        }
        return nil
    }
}

/// Where a request's time went (resolve, act, verify), on a monotonic clock.
/// A phase that did not run is absent, not 0.
nonisolated struct HarnessPhaseTiming {
    typealias Nanoseconds = UInt64
    static func now() -> Nanoseconds { DispatchTime.now().uptimeNanoseconds }

    private let requestStartedAt: Nanoseconds
    private var phaseStartedAt: Nanoseconds?
    private(set) var resolveMilliseconds: Int?
    private(set) var actMilliseconds: Int?
    private(set) var verifyMilliseconds: Int?
    private(set) var verifyWalks: Int?
    private(set) var verifyPath: String?

    init(requestStartedAt: Nanoseconds = HarnessPhaseTiming.now()) {
        self.requestStartedAt = requestStartedAt
    }

    static func milliseconds(from start: Nanoseconds, to end: Nanoseconds) -> Int {
        end > start ? Int((end - start) / 1_000_000) : 0
    }

    /// Everything before this was resolving.
    mutating func actionStarting(at instant: Nanoseconds = HarnessPhaseTiming.now()) {
        resolveMilliseconds = Self.milliseconds(from: requestStartedAt, to: instant)
        phaseStartedAt = instant
    }

    mutating func actionReturned(at instant: Nanoseconds = HarnessPhaseTiming.now()) {
        guard let started = phaseStartedAt, actMilliseconds == nil else { return }
        actMilliseconds = Self.milliseconds(from: started, to: instant)
        phaseStartedAt = instant
    }

    mutating func verified(walks: Int, path: String?, at instant: Nanoseconds = HarnessPhaseTiming.now()) {
        guard let started = phaseStartedAt, actMilliseconds != nil else { return }
        verifyMilliseconds = Self.milliseconds(from: started, to: instant)
        verifyWalks = walks
        verifyPath = path
        phaseStartedAt = nil
    }

    /// For helpers that act and wait inside one call (`focus`, `launch`).
    mutating func actedThenVerified(actMilliseconds reported: Int, walks: Int, path: String?,
                                    at instant: Nanoseconds = HarnessPhaseTiming.now()) {
        guard let started = phaseStartedAt, actMilliseconds == nil else { return }
        let call = Self.milliseconds(from: started, to: instant)
        actMilliseconds = min(max(reported, 0), call)
        verifyMilliseconds = call - (actMilliseconds ?? 0)
        verifyWalks = walks
        verifyPath = path
        phaseStartedAt = nil
    }

    var wireFields: [String: Any] {
        var fields: [String: Any] = [:]
        if let resolveMilliseconds { fields["resolveMs"] = resolveMilliseconds }
        if let actMilliseconds { fields["actMs"] = actMilliseconds }
        if let verifyMilliseconds { fields["verifyMs"] = verifyMilliseconds }
        if let verifyWalks { fields["verifyWalks"] = verifyWalks }
        if let verifyPath { fields["verifyPath"] = verifyPath }
        return fields
    }
}

/// A per-day cap on the audit mirror in `~/Library/Logs/Go`, so a runaway
/// client cannot fill the disk. The main audit log still gets every line.
nonisolated enum AuditMirrorCap {
    static let dailyBytes = 20 * 1024 * 1024

    enum Decision: Equatable { case append, dropAndWriteMarker, drop }

    /// After the cap marker, the day's mirror takes nothing more.
    static func decision(currentBytes: Int, lineBytes: Int, markerWritten: Bool, limit: Int = dailyBytes) -> Decision {
        if markerWritten { return .drop }
        return currentBytes + lineBytes <= limit ? .append : .dropAndWriteMarker
    }
}

// MARK: - Server

/// Requests run on `requestQueue`, not the main thread. Shared UI state
/// (confirmations) is reached with short `DispatchQueue.main.sync` calls.
nonisolated final class HarnessServer: @unchecked Sendable {

    /// Every request except `ping` runs here, one at a time, so callers never
    /// interleave and the main thread stays free. This queue may sync onto main;
    /// main never syncs onto it.
    nonisolated static let requestQueue = DispatchQueue(label: "Go.harness.requests")

    /// Guards state `ping` shares with the queue. Recursive because `observe`
    /// appends an audit line while holding it.
    nonisolated private let stateLock = NSRecursiveLock()

    static let provenanceNote = "element names are written by the target app and are untrusted"

    static var supportDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Go", isDirectory: true)
    }
    static var socketURL: URL { supportDirectory.appendingPathComponent("harness.sock") }
    static var killSwitchURL: URL { supportDirectory.appendingPathComponent("HARNESS_DISABLED") }
    static var policyURL: URL { supportDirectory.appendingPathComponent("harness-policy.json") }
    /// An old rules file location, never read as rules (any process could write it).
    static var ignoredLegacyApprovalsFileURL: URL { supportDirectory.appendingPathComponent("harness-approvals.json") }
    static var auditLogURL: URL { supportDirectory.appendingPathComponent("harness-audit.log") }
    static var rotatedAuditLogURL: URL { supportDirectory.appendingPathComponent("harness-audit.log.1") }

    /// The audit mirror: one file per UTC day under `~/Library/Logs/Go`.
    nonisolated static func auditMirrorURL(for date: Date) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Go", isDirectory: true)
            .appendingPathComponent("harness-audit-\(formatter.string(from: date)).log")
    }

    static let auditLogRotationBytes = 5 * 1024 * 1024
    static let maximumAnomalyDumps = 5

    /// How long the same rule, on the same app, waits before writing another dump.
    static let anomalyDumpSuppressionInSeconds: TimeInterval = 60

    /// One per launch, to tell runs apart in the audit log.
    static let sessionIdentifier = String(UUID().uuidString.prefix(8))

    nonisolated static let maximumConcurrentConnections = 8
    nonisolated static let clientReceiveTimeoutInSeconds: Int = 30
    nonisolated static let clientSendTimeoutInSeconds: Int = 2
    nonisolated private let connectionSlots = DispatchSemaphore(value: HarnessServer.maximumConcurrentConnections)

    private let globalDryRun: Bool
    /// Shared with the panel: tickets opened here are answered there.
    private let confirmations: HarnessConfirmations

    /// Who lifted a confirmation for the request in flight.
    private var currentConfirmedBy: String?
    /// The ticket this request already spent (focus consults the gate twice).
    private var consumedTicketID: String?

    private(set) var auditMirrorFailures = 0
    private(set) var auditMirrorOverflowLines = 0
    private var auditMirrorFilesMarkedAsCapped: Set<String> = []
    private var phaseTiming = HarnessPhaseTiming()

    /// The per-app policy for the request in flight; nil means no file.
    private var loadedPolicy: HarnessAppPolicy.Policy?
    private var listeningDescriptor: Int32 = -1

    /// The last 20 request/response summaries, without element arrays, written
    /// out only when an anomaly trips.
    private var flightRecorder = RingBuffer<[String: Any]>(capacity: 20)

    /// Walk durations per app; a cross-app median would flag every app switch.
    private var recentWalkMillisecondsByApp: [String: RingBuffer<Int>] = [:]

    /// Last dump time per rule and app.
    private var lastAnomalyDumpAt: [String: Date] = [:]

    init(globalDryRun: Bool, confirmations: HarnessConfirmations) {
        self.globalDryRun = globalDryRun
        self.confirmations = confirmations
    }

    var versionString: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"
        return "go-harness/1 app \(short) (\(build))"
    }

    // MARK: Lifecycle

    func start() {
        let path = Self.socketURL.path
        try? FileManager.default.createDirectory(at: Self.supportDirectory, withIntermediateDirectories: true)

        // Remove a socket file left behind by a crash.
        unlink(path)

        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            print("❌ harness: socket() failed, errno \(errno)")
            return
        }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let pathBytes = Array(path.utf8CString)
        guard pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            print("❌ harness: socket path too long for sockaddr_un: \(path)")
            close(descriptor)
            return
        }
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            pathBytes.withUnsafeBytes { source in
                destination.copyMemory(from: source)
            }
        }

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                Darwin.bind(descriptor, socketAddress, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            print("❌ harness: bind() failed, errno \(errno)")
            close(descriptor)
            return
        }

        // The file permissions are the access control: this user only.
        chmod(path, 0o600)

        guard listen(descriptor, 8) == 0 else {
            print("❌ harness: listen() failed, errno \(errno)")
            close(descriptor)
            return
        }

        listeningDescriptor = descriptor
        print("""

        ════════════════════════════════════════════════════════════════
        🔌 Go harness listening
           socket:      \(path)
           mode:        \(globalDryRun ? "DRY RUN (global --harness-dry-run)" : "live")
           kill switch: \(Self.killSwitchURL.path) \(Self.killSwitchIsPresent() ? "PRESENT — mutating verbs refused" : "(absent)")
           audit log:   \(Self.auditLogURL.path)
           try:         nc -U '\(path)'
        ════════════════════════════════════════════════════════════════

        """)

        Thread.detachNewThread { [weak self] in
            self?.acceptLoop(on: descriptor)
        }
    }

    nonisolated private func acceptLoop(on descriptor: Int32) {
        while true {
            let client = accept(descriptor, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                print("❌ harness: accept() failed, errno \(errno)")
                return
            }
            var sendTimeout = timeval(tv_sec: Self.clientSendTimeoutInSeconds, tv_usec: 0)
            setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &sendTimeout, socklen_t(MemoryLayout<timeval>.size))
            guard connectionSlots.wait(timeout: .now()) == .success else {
                _ = writeLine("{\"ok\":false,\"error\":\"tooManyConnections\",\"message\":\"\(Self.maximumConcurrentConnections) connections are already open\"}", to: client)
                close(client)
                continue
            }
            var receiveTimeout = timeval(tv_sec: Self.clientReceiveTimeoutInSeconds, tv_usec: 0)
            setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &receiveTimeout, socklen_t(MemoryLayout<timeval>.size))
            // A thread per connection; the work itself is serialised on `requestQueue`.
            Thread.detachNewThread { self.serve(client) }
        }
    }

    nonisolated static let maximumRequestBytes = 1 << 20

    /// Newline-delimited JSON in both directions.
    nonisolated private func serve(_ client: Int32) {
        defer { close(client); connectionSlots.signal() }
        var pending = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)

        while true {
            let bytesRead = read(client, &buffer, buffer.count)
            if bytesRead == 0 { return }   // peer closed
            if bytesRead < 0 {
                // A receive timeout with nothing pending is just an idle client.
                if errno == EAGAIN || errno == EWOULDBLOCK, pending.isEmpty { continue }
                return
            }
            pending.append(contentsOf: buffer[0..<bytesRead])

            // Cap the buffer so a client that never sends a newline cannot exhaust memory.
            guard pending.count <= Self.maximumRequestBytes else {
                _ = writeLine(
                    "{\"ok\":false,\"error\":\"requestTooLarge\",\"message\":\"a single request line may not exceed \(Self.maximumRequestBytes) bytes\"}",
                    to: client
                )
                // Audited after the reply, so the error never waits behind another request.
                Self.requestQueue.async { self.auditUnparsed(outcome: "requestTooLarge", startedAt: Date()) }
                return
            }

            while let newlineIndex = pending.firstIndex(of: 0x0A) {
                let lineData = pending[pending.startIndex..<newlineIndex]
                pending = pending[(newlineIndex + 1)...]
                let line = String(decoding: lineData, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if line.isEmpty { continue }

                let response = answer(line: line)
                guard writeLine(response, to: client) else { return }
            }
        }
    }

    nonisolated private func writeLine(_ text: String, to client: Int32) -> Bool {
        let payload = Array((text + "\n").utf8)
        var offset = 0
        while offset < payload.count {
            let written = payload.withUnsafeBytes { bytes in
                write(client, bytes.baseAddress!.advanced(by: offset), payload.count - offset)
            }
            if written <= 0 { return false }
            offset += written
        }
        return true
    }

    // MARK: Request handling

    static func killSwitchIsPresent() -> Bool {
        FileManager.default.fileExists(atPath: killSwitchURL.path)
    }

    /// `ping` answers immediately; everything else waits its turn on `requestQueue`.
    nonisolated func answer(line: String) -> String {
        if case .success(let request) = HarnessPolicy.decode(line: line), request.verb == .ping {
            let startedAt = Date()
            let dryRun = HarnessPolicy.effectiveDryRun(requested: request.requestedDryRun, globalDefault: globalDryRun)
            var response = pingResponse(request, dryRun: dryRun, startedAt: startedAt)
            response.merge(HarnessPhaseTiming().wireFields) { existing, _ in existing }
            response["id"] = request.id
            response["provenance"] = Self.provenanceNote
            return Self.encoded(observe(response, verb: request.verb.rawValue, startedAt: startedAt))
        }
        return Self.requestQueue.sync { respond(toLine: line) }
    }

    private func respond(toLine line: String) -> String {
        dispatchPrecondition(condition: .onQueue(Self.requestQueue))
        let startedAt = Date()
        return Self.encoded(handle(line: line, startedAt: startedAt))
    }

    nonisolated private static func encoded(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return "{\"ok\":false,\"error\":\"responseEncodingFailed\"}"
        }
        return text
    }

    private func handle(line: String, startedAt: Date) -> [String: Any] {
        switch HarnessPolicy.decode(line: line) {
        case .failure(let error):
            // A malformed line is still logged.
            auditUnparsed(outcome: error.code, startedAt: startedAt)
            return observe(
                ["ok": false, "id": "", "error": error.code, "message": error.message],
                verb: "?", startedAt: startedAt
            )

        case .success(let request):
            var response = execute(request, startedAt: startedAt)
            response.merge(phaseTiming.wireFields) { existing, _ in existing }
            response["id"] = request.id
            response["provenance"] = Self.provenanceNote
            return observe(response, verb: request.verb.rawValue, startedAt: startedAt)
        }
    }

    private func auditUnparsed(outcome: String, startedAt: Date) {
        appendAudit(HarnessPolicy.auditLine(
            at: startedAt, id: "", verb: "?", target: nil,
            app: Self.frontmostBundleIdentifier(), session: Self.sessionIdentifier,
            dryRun: globalDryRun, confirmed: false,
            kernel: "n/a", outcome: outcome,
            milliseconds: elapsedMilliseconds(since: startedAt)
        ), at: startedAt)
    }

    /// Anomaly checks and the audit line, on the way out.
    private func observe(
        _ response: [String: Any],
        verb: String,
        startedAt: Date
    ) -> [String: Any] {
        var summary = Self.summaryForRing(response)
        summary["_verb"] = verb
        summary["_at"] = HarnessPolicy.auditTimestampFormatter.string(from: startedAt)

        let walkMilliseconds = response["walkMilliseconds"] as? Int
        let walkedApp = (response["bundleIdentifier"] as? String) ?? "unknown"

        // The lock never covers cross-process reads, which could stall `ping`.
        let (anomaly, recentWalkElements): (HarnessAnomaly?, [Int]) = stateLock.withLock {
            var recentWalks = recentWalkMillisecondsByApp[walkedApp] ?? RingBuffer<Int>(capacity: 20)
            let anomaly = HarnessObservability.anomaly(
                kernelDecision: (response["kernel"] as? [String: Any])?["decision"] as? String,
                kernelReason: (response["kernel"] as? [String: Any])?["reason"] as? String,
                verificationStatus: (response["verification"] as? [String: Any])?["status"] as? String,
                errorCode: response["error"] as? String,
                walkMilliseconds: walkMilliseconds,
                recentWalkMilliseconds: recentWalks.elements
            )
            flightRecorder.append(summary)
            if let walkMilliseconds {
                recentWalks.append(walkMilliseconds)
                recentWalkMillisecondsByApp[walkedApp] = recentWalks
            }
            return (anomaly, recentWalks.elements)
        }

        guard let anomaly else { return response }

        // Suppress repeat dumps for the same rule and app within the window.
        let frontmostApp = Self.frontmostBundleIdentifier()
        let dumpKey = "\(anomaly.rawValue)|\(frontmostApp ?? "unknown")"
        let now = Date()
        let (suppressed, ringRequests) = stateLock.withLock {
            (lastAnomalyDumpAt[dumpKey].map { now.timeIntervalSince($0) < Self.anomalyDumpSuppressionInSeconds } ?? false,
             flightRecorder.elements)
        }

        var annotated = response
        var outcome = "anomalyNotWritten"
        if suppressed {
            outcome = "anomalySuppressed"
            annotated["anomaly"] = [
                "rule": anomaly.rawValue,
                "dump": NSNull(),
                "suppressed": "same rule and app dumped within the last \(Int(Self.anomalyDumpSuppressionInSeconds))s"
            ]
        } else if let dumpPath = writeAnomalyDump(
            anomaly, app: frontmostApp, walkedApp: walkedApp, recentWalks: recentWalkElements, requests: ringRequests
        ) {
            stateLock.withLock { lastAnomalyDumpAt[dumpKey] = now }
            outcome = "anomaly"
            annotated["anomaly"] = ["rule": anomaly.rawValue, "dump": dumpPath]
        }

        // Audit every anomaly, including suppressed ones.
        appendAudit(HarnessPolicy.auditLine(
            at: now, id: (response["id"] as? String) ?? "", verb: verb,
            target: anomaly.rawValue,
            app: frontmostApp, session: Self.sessionIdentifier,
            dryRun: globalDryRun, confirmed: false,
            kernel: "n/a", outcome: outcome,
            milliseconds: elapsedMilliseconds(since: startedAt)
        ), at: now)
        return annotated
    }

    /// Large arrays are dropped from the ring; their counts stay.
    nonisolated static let ringStrippedArrays = ["elements", "items", "windows", "applications", "candidates", "processesFailed"]

    nonisolated static func summaryForRing(_ response: [String: Any]) -> [String: Any] {
        var summary = response
        for key in ringStrippedArrays {
            guard let array = response[key] as? [Any] else { continue }
            summary[key] = nil
            let countKey = key.hasSuffix("s") ? String(key.dropLast()) + "Count" : key + "Count"
            if summary[countKey] == nil { summary[countKey] = array.count }
        }
        return summary
    }

    /// Writes the ring buffer out, keeping at most five files.
    private func writeAnomalyDump(
        _ anomaly: HarnessAnomaly,
        app: String?,
        walkedApp: String,
        recentWalks: [Int],
        requests: [[String: Any]]
    ) -> String? {
        let timestamp = HarnessPolicy.auditTimestampFormatter.string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let url = Self.supportDirectory
            .appendingPathComponent("harness-anomaly-\(timestamp).json")

        let payload: [String: Any] = [
            "rule": anomaly.rawValue,
            "session": Self.sessionIdentifier,
            "app": app.map { $0 as Any } ?? NSNull(),
            "walkedApp": walkedApp,
            "recentWalkMilliseconds": recentWalks,
            "requests": requests
        ]
        guard let data = try? JSONSerialization.data(
            withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]
        ) else { return nil }

        try? FileManager.default.createDirectory(at: Self.supportDirectory, withIntermediateDirectories: true)
        guard Self.append(data, to: url) else { return nil }
        pruneAnomalyDumps()
        return url.path
    }

    private func pruneAnomalyDumps() {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: Self.supportDirectory, includingPropertiesForKeys: nil
        )) ?? []
        let dumps = contents
            .filter { $0.lastPathComponent.hasPrefix("harness-anomaly-") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard dumps.count > Self.maximumAnomalyDumps else { return }
        for stale in dumps.prefix(dumps.count - Self.maximumAnomalyDumps) {
            try? FileManager.default.removeItem(at: stale)
        }
    }

    /// The frontmost app's bundle id (Go never takes focus itself).
    static func frontmostBundleIdentifier() -> String? {
        AccessibilityTreeWalker.focusedApplication()?.bundleIdentifier
    }

    nonisolated static func isHarnessItself(bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier, let own = Bundle.main.bundleIdentifier else { return false }
        return bundleIdentifier.caseInsensitiveCompare(own) == .orderedSame
    }

    nonisolated static let harnessItselfMessage =
        "the target is Go itself — the harness never reads or acts on its own UI (approval rules, quit, toggles)"

    /// Refuses a request aimed at Go itself, or whose `expectApp` does not match
    /// the app it just read. Nil when the verb may go on.
    private func frontmostChangedRefusal(
        _ request: HarnessRequest,
        name: String?,
        bundleIdentifier: String?,
        dryRun: Bool,
        startedAt: Date
    ) -> [String: Any]? {
        if Self.isHarnessItself(bundleIdentifier: bundleIdentifier) {
            audit(request, dryRun: dryRun, kernel: "n/a", outcome: "targetIsHarnessItself", startedAt: startedAt)
            return ["ok": false, "error": "targetIsHarnessItself", "message": Self.harnessItselfMessage]
        }
        guard let expected = request.expectApp,
              !HarnessPolicy.appMatches(expected: expected, bundleIdentifier: bundleIdentifier, name: name)
        else { return nil }
        audit(request, dryRun: dryRun, kernel: "n/a", outcome: "frontmostChanged", startedAt: startedAt)
        return [
            "ok": false,
            "error": "frontmostChanged",
            "expectedApp": expected,
            "actualApp": [
                "name": name.map { $0 as Any } ?? NSNull(),
                "bundleIdentifier": bundleIdentifier.map { $0 as Any } ?? NSNull()
            ],
            "message": "focus is not on the expected application \(UntrustedText(expected).forDisplay) — "
                + "\(UntrustedText(name ?? bundleIdentifier ?? "unknown").forDisplay) is frontmost, "
                + "so nothing was resolved or performed"
        ]
    }

    private func execute(_ request: HarnessRequest, startedAt: Date) -> [String: Any] {
        phaseTiming = HarnessPhaseTiming()
        let dryRun = HarnessPolicy.effectiveDryRun(
            requested: request.requestedDryRun,
            globalDefault: globalDryRun
        )

        if let killSwitchReason = HarnessPolicy.killSwitchRefusal(
            verb: request.verb,
            killSwitchPresent: Self.killSwitchIsPresent()
        ) {
            audit(request, dryRun: dryRun, kernel: "n/a", outcome: "killSwitch", startedAt: startedAt)
            return ["ok": false, "error": "killSwitch", "message": killSwitchReason]
        }

        // Read once per request and fail closed: an unreadable policy never allows.
        loadedPolicy = nil
        currentConfirmedBy = nil
        consumedTicketID = nil
        // `look` takes a picture, and a `refuse` policy covers pictures too.
        if request.verb.isMutating || request.verb == .look {
            switch HarnessAppPolicy.load(from: Self.policyURL) {
            case .loaded(let policy, _): loadedPolicy = policy
            case .missing: break
            case .unreadable(let reason):
                audit(request, dryRun: dryRun, kernel: "n/a", outcome: "policyUnreadable", startedAt: startedAt)
                return ["ok": false, "error": "policyUnreadable",
                        "message": "harness policy file is unreadable or malformed — \(reason)"]
            }
        }

        switch request.verb {
        case .ping:
            return pingResponse(request, dryRun: dryRun, startedAt: startedAt)

        case .snapshot:
            return snapshotResponse(request, dryRun: dryRun, startedAt: startedAt)

        case .press, .select, .type, .open:
            return actResponse(request, dryRun: dryRun, startedAt: startedAt)

        case .menu:
            return request.statusItem != nil
                ? statusItemPressResponse(request, dryRun: dryRun, startedAt: startedAt)
                : menuResponse(request, dryRun: dryRun, startedAt: startedAt)

        case .status:
            return statusResponse(request, dryRun: dryRun, startedAt: startedAt)

        case .menus:
            return menusResponse(request, dryRun: dryRun, startedAt: startedAt)

        case .windows:
            return windowsResponse(request, dryRun: dryRun, startedAt: startedAt)

        case .focus:
            return focusResponse(request, dryRun: dryRun, startedAt: startedAt)

        case .look:
            return lookResponse(request, dryRun: dryRun, startedAt: startedAt)

        case .launch:
            return launchResponse(request, dryRun: dryRun, startedAt: startedAt)

        case .highlight:
            return highlightResponse(request, dryRun: dryRun, startedAt: startedAt)
        }
    }

    // MARK: snapshot

    private func snapshotResponse(_ request: HarnessRequest, dryRun: Bool, startedAt: Date) -> [String: Any] {
        let snapshot: AccessibilityWindowSnapshot
        do {
            snapshot = try AccessibilityTreeWalker.snapshotFocusedWindow()
        } catch {
            let code = Self.errorCode(for: error)
            audit(request, dryRun: dryRun, kernel: "n/a", outcome: code, startedAt: startedAt)
            return ["ok": false, "error": code, "message": String(describing: error)]
        }

        if let refusal = frontmostChangedRefusal(
            request, name: snapshot.applicationName, bundleIdentifier: snapshot.bundleIdentifier,
            dryRun: dryRun, startedAt: startedAt
        ) { return refusal }

        guard let rootNode = snapshot.rootNode else {
            audit(request, dryRun: dryRun, kernel: "n/a", outcome: "noRootNode", startedAt: startedAt)
            return ["ok": false, "error": "noRootNode", "message": "the walk produced no root element"]
        }

        let actionable = rootNode.flattenedDescendants().filter(\.isActionable)
        audit(request, dryRun: dryRun, kernel: "n/a", outcome: "ok", startedAt: startedAt)

        return [
            "ok": true,
            "application": snapshot.applicationName,
            "bundleIdentifier": snapshot.bundleIdentifier,
            "nodeCount": snapshot.nodeCount,
            "walkMilliseconds": Int(snapshot.walkDurationInSeconds * 1000),
            // Truncation is always reported.
            "walkStopReasons": snapshot.walkStopReasons.map(\.rawValue).sorted(),
            "focusChangedDuringWalk": snapshot.focusChangedDuringWalk,
            "incompleteReads": !snapshot.timedOutNodePaths.isEmpty || snapshot.subtreesLostToFailedReads > 0,
            "window": [
                "name": rootNode.displayName.flatMap { $0.isPlausibleControlLabel ? $0.raw : nil } ?? "",
                "token": rootNode.accessibilityElement.map { String(CFHash($0)) } ?? "",
                "frame": Self.frameJSON(rootNode.frameInAppKitCoordinates).frame
            ],
            "frontmostSource": snapshot.frontmostSource?.rawValue ?? NSNull(),
            "actionableCount": actionable.count,
            "elements": actionable.map(Self.summarise)
        ]
    }

    /// The wire form of an element, with a flag saying whether the name is a
    /// plausible label.
    static func summarise(_ node: AccessibilityElementNode) -> [String: Any] {
        var entry: [String: Any] = [
            "role": node.role,
            "subrole": node.subrole ?? NSNull(),
            "name": node.displayName?.raw ?? NSNull(),
            "nameIsPlausibleLabel": node.displayName?.isPlausibleControlLabel ?? false,
            "actions": node.publishedActionNames
        ]
        if node.role == kAXRadioButtonRole {
            entry["radioSelection"] = node.radioSelection.map { $0 as Any } ?? NSNull()
        }
        Self.attachFrame(node.frameInAppKitCoordinates, to: &entry)
        return entry
    }

    /// Non-finite frame values become null and are flagged, instead of breaking
    /// the whole JSON response.
    nonisolated static func frameJSON(_ rect: CGRect) -> (frame: [String: Any], invalid: Bool) {
        let components: [(String, CGFloat)] = [
            ("x", rect.origin.x), ("y", rect.origin.y), ("w", rect.size.width), ("h", rect.size.height)
        ]
        var frame: [String: Any] = [:]
        var invalid = false
        for (key, value) in components {
            if value.isFinite { frame[key] = value } else { frame[key] = NSNull(); invalid = true }
        }
        return (frame, invalid)
    }

    nonisolated static func pointJSON(_ point: CGPoint) -> (point: [String: Any], invalid: Bool) {
        let (frame, invalid) = frameJSON(CGRect(origin: point, size: CGSize(width: 1, height: 1)))
        return (["x": frame["x"]!, "y": frame["y"]!], invalid)
    }

    nonisolated static func attachFrame(_ rect: CGRect, to entry: inout [String: Any], key: String = "frame") {
        let (frame, invalid) = frameJSON(rect)
        entry[key] = frame
        if invalid { entry["frameInvalid"] = true }
    }

    // MARK: press / select

    /// Applies the per-app policy over the kernel's decision.
    private func applyAppPolicy(
        to kernel: SafetyDecision, bundleIdentifier: String?, into response: inout [String: Any]
    ) -> SafetyDecision {
        let (verdict, source) = HarnessAppPolicy.verdict(for: bundleIdentifier, in: loadedPolicy)
        response["policy"] = policyBlock(verdict: verdict, source: source, bundleIdentifier: bundleIdentifier)
        return HarnessAppPolicy.compose(policy: verdict, bundleIdentifier: bundleIdentifier, kernel: kernel)
    }

    private func policyBlock(verdict: HarnessAppPolicy.Verdict, source: String, bundleIdentifier: String?) -> [String: Any] {
        ["verdict": verdict.rawValue, "source": source, "app": (bundleIdentifier ?? NSNull()) as Any]
    }

    // MARK: Confirmation gate

    struct GateResult {
        let executable: Bool
        let decision: String
        let outcome: String
        let note: String?
    }

    /// Where a kernel decision meets approval. A question becomes a ticket the
    /// user answers in the panel; the caller re-issues with its id.
    private func gate(
        _ decision: SafetyDecision,
        request: HarnessRequest,
        appName: String?,
        bundleIdentifier: String?,
        dryRun: Bool,
        bindingSubject: ActionBinding.Subject? = nil,
        into response: inout [String: Any]
    ) -> GateResult {
        let described = HarnessPolicy.describe(decision)
        let result: GateResult

        switch decision {
        case .allow:
            result = GateResult(executable: true, decision: described.decision, outcome: "allowed", note: nil)

        case .refuse(let reason):
            result = GateResult(executable: false, decision: described.decision,
                                outcome: "kernelRefused", note: "refused: \(reason)")

        case .requireConfirmation(let reason, let destructive):
            let shape = Self.confirmationShape(for: request, bundleIdentifier: bundleIdentifier)
            var confirmedBy: String?
            var confirmation: [String: Any] = [:]
            var refusal: (outcome: String, note: String)?

            if let id = request.ticket {
                // Check the approved selection still matches before spending the ticket.
                // Ticket state lives on main because SwiftUI observes it.
                let (peek, approvedBinding) = DispatchQueue.main.sync {
                    (confirmations.consume(ticket: id, shape, spend: false), confirmations.ticket(id: id)?.binding)
                }
                if let bindingSubject, let approved = approvedBinding,
                   peek == .pending || peek == .allowed {
                    let recheck = ActionBinding.recheck(approved, subject: bindingSubject, bundleIdentifier: bundleIdentifier)
                    if let moved = recheck.movedPart {
                        DispatchQueue.main.sync { confirmations.invalidateAsStale(ticket: id, movedPart: moved) }
                    }
                    response["binding"] = ActionBinding.responsePayload(recheck.current, bundleIdentifier: bundleIdentifier,
                                                                        stalePart: recheck.movedPart)
                }
                // A dry run reports the decision and leaves the ticket unspent.
                switch DispatchQueue.main.sync(execute: { confirmations.consume(ticket: id, shape, spend: !dryRun) }) {
                case .allowed:
                    confirmedBy = "owner"
                    confirmation["ticket"] = id
                    if dryRun { confirmation["dryRun"] = true } else { consumedTicketID = id }
                case .consumed where id == consumedTicketID:
                    confirmedBy = "owner"
                    confirmation["ticket"] = id
                case .pending:
                    refusal = ("confirmationPending", "ticket \(id) has not been answered in the Go panel yet")
                case .denied:
                    refusal = ("confirmationDenied", "ticket \(id) was denied in the Go panel")
                case .expired:
                    refusal = ("confirmationExpired",
                               "ticket \(id) expired after \(Int(HarnessConfirmations.ticketLifetimeInSeconds)) s — re-issue without it to open a new one")
                case .consumed:
                    refusal = ("confirmationTicketInvalid", "ticket \(id) was already spent — one ticket, one action")
                case .unknown:
                    refusal = ("confirmationTicketInvalid", "no ticket \(id) is known to this harness session")
                case .mismatch(let field):
                    refusal = ("confirmationTicketInvalid", "ticket \(id) was issued for a different \(field)")
                case .stale(let field):
                    refusal = ("confirmationStale",
                               "ticket \(id) is stale: the \(field) it was approved for has changed — re-issue without it to ask again")
                }
            } else {
                let consulted = confirmations.rule(for: shape, destructive: destructive)
                var approvalsReport: [String: Any] = [:]
                if let unreadable = consulted.unreadable { approvalsReport["unreadable"] = unreadable }
                // A planted rules file is reported, never honoured.
                if let ignoredFile = consulted.ignoredFile { approvalsReport["ignoredFile"] = ignoredFile }
                if !approvalsReport.isEmpty { response["approvals"] = approvalsReport }
                if let rule = consulted.rule {
                    confirmedBy = "approvalRule"
                    confirmation["rule"] = [
                        "bundleIdentifier": rule.bundleIdentifier, "verb": rule.verb,
                        "target": (rule.target ?? NSNull()) as Any,
                        "text": (rule.text ?? NSNull()) as Any,
                        "mode": (rule.mode ?? NSNull()) as Any,
                        "withinNamed": (rule.withinNamed ?? NSNull()) as Any,
                        "nearPoint": (rule.nearPoint.map { [$0.x, $0.y] } ?? NSNull()) as Any,
                        "role": (rule.role ?? NSNull()) as Any,
                        "thenConfirm": rule.thenConfirm ?? false
                    ]
                } else if GoTrustedMode.approves(destructive: destructive) {
                    // Trusted mode approves non-destructive questions without a card.
                    confirmedBy = "trustedMode"
                    confirmation["trustedMode"] = true
                } else {
                    let binding = bindingSubject.map { ActionBinding.capture($0, bundleIdentifier: bundleIdentifier) }
                    if let binding {
                        response["binding"] = ActionBinding.responsePayload(binding, bundleIdentifier: bundleIdentifier)
                    }
                    switch DispatchQueue.main.sync(execute: {
                        confirmations.open(shape, appName: appName, reason: reason, destructive: destructive, binding: binding)
                    }) {
                    case .opened(let ticket):
                        response["ticket"] = ticket.id
                        response["expiresAt"] = HarnessPolicy.auditTimestampFormatter.string(from: ticket.expiresAt)
                        response["message"] = "re-issue this request with \"ticket\": \"\(ticket.id)\" once approved in the Go panel"
                        refusal = ("confirmationRequired",
                                   "requires confirmation: \(reason) — ticket \(ticket.id) is waiting in the Go panel")
                    case .refused(let code, let message):
                        response["message"] = message
                        refusal = (code, "requires confirmation: \(reason) — no ticket opened: \(message)")
                    }
                }
            }

            if let refusal {
                result = GateResult(executable: false, decision: described.decision,
                                    outcome: refusal.outcome, note: refusal.note)
            } else {
                let by = confirmedBy ?? "owner"
                currentConfirmedBy = by
                confirmation["by"] = by
                response["confirmation"] = confirmation
                result = GateResult(executable: true, decision: described.decision,
                                    outcome: "allowed", note: "confirmed by \(by): \(reason)")
            }
        }

        response["kernel"] = [
            "decision": result.decision,
            "reason": (described.reason ?? NSNull()) as Any,
            "executable": result.executable,
            "note": (result.note ?? NSNull()) as Any
        ]
        return result
    }

    /// The request shape a ticket or rule is matched against.
    nonisolated static func confirmationShape(for request: HarnessRequest, bundleIdentifier: String?) -> HarnessConfirmations.Shape {
        HarnessConfirmations.Shape(
            verb: request.verb.rawValue,
            bundleIdentifier: bundleIdentifier,
            rawTarget: auditTarget(for: request) ?? "",
            text: request.verb == .type ? request.text : nil,
            mode: request.verb == .type ? request.mode.rawValue : nil,
            withinNamed: request.withinNamed,
            nearPoint: request.nearPoint,
            role: request.role,
            thenConfirm: request.thenConfirm
        )
    }

    /// What a request acted on, for the audit line and the ticket.
    nonisolated static func auditTarget(for request: HarnessRequest) -> String? {
        if !request.title.isEmpty { return request.title }
        if !request.path.isEmpty { return request.path.joined(separator: " > ") }
        if let statusItem = request.statusItem, !statusItem.isEmpty { return statusItem }
        if request.aimAtFocus { return "<focused>" }
        if request.aimAtWindow { return "<window>" }
        return request.app
    }

    // MARK: highlight

    /// Outline the element a press with the same fields would resolve. Sends the
    /// target app nothing, so no policy or ticket applies.
    private func highlightResponse(_ request: HarnessRequest, dryRun: Bool, startedAt: Date) -> [String: Any] {
        var response: [String: Any] = ["dryRun": dryRun]
        guard let target = resolveTarget(request, action: .press, dryRun: dryRun, startedAt: startedAt, into: &response)
        else { return response }
        response["resolved"] = Self.summarise(target.node)

        func refuse(_ code: String, _ message: String) -> [String: Any] {
            response["ok"] = false
            response["error"] = code
            response["message"] = message
            audit(request, dryRun: dryRun, kernel: "n/a", outcome: code, startedAt: startedAt)
            return response
        }

        // Check reachability before the live read: scrolled-out rows fail that read.
        if let reason = ActionSafetyKernel.unreachableFrameReason(
            target.node.frameInAppKitCoordinates, visibleBounds: target.rootNode.frameInAppKitCoordinates
        ) {
            return refuse("targetNotOnScreen", reason)
        }
        // Read the frame straight from AX, not the walk's converted copy.
        guard let element = target.node.accessibilityElement,
              let elementFrame = AccessibilityTreeWalker.copyFrame(from: element).frame else {
            return refuse("frameUnreadable", "the element's AXPosition/AXSize could not be read")
        }
        let drawnRect = AccessibilityTreeWalker.convertAccessibilityFrameToAppKitFrame(
            elementFrame, primaryDisplayHeightInPoints: CGDisplayBounds(CGMainDisplayID()).height
        )
        guard let screenIndex = ScreenCaptureUtility.bestDisplayIndex(
            for: drawnRect, among: DispatchQueue.main.sync { NSScreen.screens.map(\.frame) }
        ) else {
            return refuse("targetNotOnScreen", "the element's frame is on no display")
        }

        phaseTiming.actionStarting()
        // Shown after the request returns, so no second request lands inside this one.
        let seconds = request.highlightSeconds, label = request.label
        DispatchQueue.main.async {
            ElementHighlightOverlay.show(drawnRect, label: label, onScreenAt: screenIndex, seconds: seconds)
        }

        response["ok"] = true
        Self.attachFrame(elementFrame, to: &response, key: "elementFrame")
        Self.attachFrame(drawnRect, to: &response, key: "drawnRect")
        response["screen"] = screenIndex
        response["seconds"] = seconds
        audit(request, dryRun: dryRun, kernel: "n/a", outcome: "highlighted", startedAt: startedAt)
        return response
    }

    /// Walk, check `expectApp` and resolve the element, or write the refusal and
    /// return nil. Shared with `highlight` so it outlines what a press would hit.
    private func resolveTarget(
        _ request: HarnessRequest, action: ElementAction, dryRun: Bool, startedAt: Date,
        into response: inout [String: Any]
    ) -> (snapshot: AccessibilityWindowSnapshot, rootNode: AccessibilityElementNode,
          intent: ElementActionIntent, node: AccessibilityElementNode)? {
        let snapshot: AccessibilityWindowSnapshot
        do {
            snapshot = try AccessibilityTreeWalker.snapshotFocusedWindow()
        } catch {
            let code = Self.errorCode(for: error)
            audit(request, dryRun: dryRun, kernel: "n/a", outcome: code, startedAt: startedAt)
            response["ok"] = false
            response["error"] = code
            response["message"] = String(describing: error)
            return nil
        }

        if let refusal = frontmostChangedRefusal(
            request, name: snapshot.applicationName, bundleIdentifier: snapshot.bundleIdentifier,
            dryRun: dryRun, startedAt: startedAt
        ) {
            response.merge(refusal) { _, new in new }
            return nil
        }

        guard let rootNode = snapshot.rootNode else {
            audit(request, dryRun: dryRun, kernel: "n/a", outcome: "noRootNode", startedAt: startedAt)
            response["ok"] = false
            response["error"] = "noRootNode"
            return nil
        }
        response["application"] = snapshot.applicationName
        response["bundleIdentifier"] = snapshot.bundleIdentifier
        response["frontmostSource"] = snapshot.frontmostSource?.rawValue ?? NSNull()
        response["walkMilliseconds"] = Int(snapshot.walkDurationInSeconds * 1000)

        let intent = ElementActionIntent(
            role: request.role,
            title: request.title,
            action: action,
            nearPoint: request.nearPoint,
            withinNamed: request.withinNamed
        )

        let resolvedNode: AccessibilityElementNode
        if request.aimAtWindow {
            resolvedNode = rootNode
            response["resolution"] = ["status": "window", "matchCount": 1]
        } else if request.aimAtFocus {
            // Focused fields are often anonymous; the OS identifies them.
            guard let focusedNode = AccessibilityTypePerformer.focusedNode() else {
                response["resolution"] = ["status": "noFocusedElement", "matchCount": 0]
                response["ok"] = false
                response["error"] = "noFocusedElement"
                audit(request, dryRun: dryRun, kernel: "n/a", outcome: "noFocusedElement", startedAt: startedAt)
                return nil
            }
            resolvedNode = focusedNode
            response["resolution"] = ["status": "focused", "matchCount": 1]
        } else {
            switch ElementActionIntentResolver.resolve(intent, inTreeRootedAt: rootNode) {
            case .resolved(let node):
                resolvedNode = node
                response["resolution"] = ["status": "resolved", "matchCount": 1]
            case .notFound:
                response["resolution"] = ["status": "notFound", "matchCount": 0]
                response["ok"] = false
                response["error"] = "notFound"
                // Offer the escalation ladder for `notFound` and `ambiguous`.
                attachEscalation(to: &response, request: request, rootNode: rootNode, application: snapshot.application)
                audit(request, dryRun: dryRun, kernel: "n/a", outcome: "notFound", startedAt: startedAt)
                return nil
            case .ambiguous(let matchCount):
                response["resolution"] = ["status": "ambiguous", "matchCount": matchCount]
                response["ok"] = false
                response["error"] = "ambiguous"
                // Free first rung: each match with a container name that separates it.
                let suggestions = ElementActionIntentResolver.containerSuggestions(
                    for: intent, inTreeRootedAt: rootNode
                )
                response["candidates"] = suggestions.prefix(Self.maximumCandidates).enumerated().map {
                    index, suggestion -> [String: Any] in
                    var entry = Self.summarise(suggestion.node)
                    entry["index"] = index
                    entry["suggestedWithinNamed"] = suggestion.suggestedWithinNamed ?? NSNull()
                    entry["resolver"] = "elementName"
                    return entry
                }
                if suggestions.count > Self.maximumCandidates {
                    response["candidatesTruncated"] = true
                    response["warning"] = "THIS LIST IS A FLOOR, NOT A MEASUREMENT — showing "
                        + "\(Self.maximumCandidates) of \(suggestions.count) matches"
                }
                attachEscalation(to: &response, request: request, rootNode: rootNode, application: snapshot.application)
                audit(request, dryRun: dryRun, kernel: "n/a", outcome: "ambiguous", startedAt: startedAt)
                return nil
            }
        }
        return (snapshot, rootNode, intent, resolvedNode)
    }

    private func actResponse(_ request: HarnessRequest, dryRun: Bool, startedAt: Date) -> [String: Any] {
        guard let action = request.verb.elementAction else {
            return ["ok": false, "error": "unknownVerb", "message": "not an acting verb"]
        }

        var response: [String: Any] = ["dryRun": dryRun, "confirmed": request.confirmed]

        guard let target = resolveTarget(request, action: action, dryRun: dryRun, startedAt: startedAt, into: &response)
        else { return response }
        let (snapshot, rootNode, intent, resolvedNode) = target
        response["resolved"] = Self.summarise(resolvedNode)

        // What the element says about being typed into (skipped for secure fields).
        var typingContext: ActionSafetyKernel.TypingContext?
        if request.verb == .type, resolvedNode.subrole != ActionSafetyKernel.secureFieldSubrole {
            let element = resolvedNode.accessibilityElement
            let settable = element.map(AccessibilityTypePerformer.settableAttributes) ?? []
            let currentValue = element.flatMap(AccessibilityTypePerformer.stringValue) ?? ""
            typingContext = ActionSafetyKernel.TypingContext(
                mode: request.mode,
                settableAttributes: settable,
                currentValueLength: currentValue.count,
                aimedByFocus: request.aimAtFocus
            )
            response["field"] = [
                "settableAttributes": settable.sorted(),
                "valueLength": currentValue.count,
                "mode": request.mode.rawValue
            ]
        }

        let decision = applyAppPolicy(
            to: ActionSafetyKernel.evaluate(
                intent: intent,
                resolvedNode: resolvedNode,
                matchCount: 1,
                visibleBounds: rootNode.frameInAppKitCoordinates,
                typing: typingContext
            ),
            bundleIdentifier: snapshot.bundleIdentifier, into: &response
        )
        let described = HarnessPolicy.describe(decision)
        // select changes the selection, so it is not bound to one.
        let bindingSubject = request.verb == .select ? nil : ActionBinding.Subject(
            targetElement: resolvedNode.accessibilityElement, processIdentifier: snapshot.application?.processIdentifier
        )
        let gated = gate(decision, request: request, appName: snapshot.applicationName,
                         bundleIdentifier: snapshot.bundleIdentifier, dryRun: dryRun,
                         bindingSubject: bindingSubject, into: &response)

        guard gated.executable else {
            response["ok"] = false
            response["error"] = gated.outcome
            audit(request, dryRun: dryRun, kernel: described.decision, outcome: gated.outcome, startedAt: startedAt)
            return response
        }

        guard !dryRun else {
            response["ok"] = true
            response["performed"] = ["status": "skipped", "reason": "dry run — nothing was performed"]
            audit(request, dryRun: dryRun, kernel: described.decision, outcome: "dryRun", startedAt: startedAt)
            return response
        }

        // Diff every name, not just pressable ones: navigation changes content.
        let namesBefore = rootNode.namedElementFingerprint
        let verifiesRadioSelection = action == .press && resolvedNode.role == kAXRadioButtonRole

        let performedOK: Bool
        switch action {
        case .press, .open, .menu:
            guard let element = resolvedNode.accessibilityElement else {
                response["ok"] = false
                response["error"] = "noLiveElement"
                audit(request, dryRun: dryRun, kernel: described.decision, outcome: "noLiveElement", startedAt: startedAt)
                return response
            }
            phaseTiming.actionStarting()
            let result = AccessibilityActionPerformer.perform(
                action.accessibilityActionName ?? kAXPressAction, on: element
            )
            // Include the raw error and the elapsed time to tell app refusal from timeout.
            response["performed"] = [
                "status": result.error == .success ? "sent" : "failed",
                "axErrorRawValue": result.error.rawValue,
                "milliseconds": result.milliseconds
            ]
            performedOK = result.error == .success

        case .select:
            guard let chain = AccessibilitySelectionPerformer.ancestorChain(to: resolvedNode, from: rootNode) else {
                response["ok"] = false
                response["error"] = "noAncestorChain"
                audit(request, dryRun: dryRun, kernel: described.decision, outcome: "noAncestorChain", startedAt: startedAt)
                return response
            }
            phaseTiming.actionStarting()
            let outcome = AccessibilitySelectionPerformer.select(chainFromRoot: chain)
            switch outcome {
            case .selected(let path, let levelsUp, let milliseconds, let readBackTrue):
                response["performed"] = [
                    "status": "sent",
                    "selectionPath": path.rawValue,
                    "levelsAboveNamedElement": levelsUp,
                    "selectedRole": chain[chain.count - 1 - levelsUp].role,
                    "milliseconds": milliseconds,
                    "readBackSelected": readBackTrue
                ]
                performedOK = true
            case .alreadySelected(let path, let levelsUp):
                response["performed"] = [
                    "status": "alreadySelected",
                    "selectionPath": path.rawValue,
                    "levelsAboveNamedElement": levelsUp,
                    "selectedRole": chain[chain.count - 1 - levelsUp].role
                ]
                response["verification"] = [
                    "status": "notNeeded",
                    "reason": "the container's selection already is exactly this row — nothing was written, so there is nothing to verify"
                ]
                response["ok"] = true
                phaseTiming.actionReturned()
                audit(request, dryRun: dryRun, kernel: described.decision, outcome: "alreadySelected", startedAt: startedAt)
                return response
            case .writeFailed(let error, let levelsUp, let milliseconds):
                response["performed"] = [
                    "status": "failed",
                    "axErrorRawValue": error.rawValue,
                    "levelsAboveNamedElement": levelsUp,
                    "milliseconds": milliseconds
                ]
                performedOK = false
            case .noSelectableAncestor(let levelsInspected):
                response["performed"] = ["status": "noSelectableAncestor", "levelsInspected": levelsInspected]
                performedOK = false
            case .noLiveElement:
                response["performed"] = ["status": "noLiveElement"]
                performedOK = false
            }

        case .type:
            guard let element = resolvedNode.accessibilityElement else {
                response["ok"] = false
                response["error"] = "noLiveElement"
                audit(request, dryRun: dryRun, kernel: described.decision, outcome: "noLiveElement", startedAt: startedAt)
                return response
            }

            phaseTiming.actionStarting()
            let outcome = AccessibilityTypePerformer.type(request.text, mode: request.mode, into: element)

            // For typing, the read-back is the evidence; the app reacting is reported separately.
            let containsWhatWeWrote = outcome.valueAfter?.contains(request.text) ?? false
            response["performed"] = [
                "status": outcome.error == .success ? "sent" : "failed",
                "attributeWritten": outcome.attributeWritten,
                "axErrorRawValue": outcome.error.rawValue,
                "milliseconds": outcome.milliseconds,
                "valueLengthBefore": outcome.valueLengthBefore,
                "valueLengthAfter": outcome.valueAfter?.count ?? NSNull(),
                "valueAfter": outcome.valueAfter.map { UntrustedText($0).forDisplay } ?? NSNull(),
                "readBackContainsText": containsWhatWeWrote
            ]
            // Success means the field contains what we wrote, not just `.success`.
            performedOK = outcome.error == .success && containsWhatWeWrote

            if request.thenConfirm {
                // A missing AXConfirm is not a failure: many fields apply text live.
                let publishesConfirm = resolvedNode.publishedActionNames.contains(kAXConfirmAction)
                if publishesConfirm {
                    let confirmResult = AccessibilityActionPerformer.perform(kAXConfirmAction, on: element)
                    response["confirm"] = [
                        "published": true,
                        "axErrorRawValue": confirmResult.error.rawValue,
                        "milliseconds": confirmResult.milliseconds
                    ]
                } else {
                    response["confirm"] = ["published": false]
                }
            }
        }

        phaseTiming.actionReturned()
        guard performedOK else {
            response["ok"] = false
            response["error"] = "performFailed"
            audit(request, dryRun: dryRun, kernel: described.decision, outcome: "performFailed", startedAt: startedAt)
            return response
        }

        // `.success` only means delivered; a second read decides whether it worked.
        let (verification, verifyWalks, confirmingSnapshot) = ActionVerifier.verifyCountingWalks { laterSnapshot in
            guard let laterRoot = laterSnapshot.rootNode else { return false }
            if verifiesRadioSelection {
                guard !laterSnapshot.focusChangedDuringWalk,
                      laterSnapshot.walkStopReasons.isEmpty,
                      laterSnapshot.bundleIdentifier == snapshot.bundleIdentifier else { return false }
                return ActionVerifier.radioPressConfirmed(intent: intent, previous: resolvedNode, laterRoot: laterRoot)
            }
            return laterRoot.namedElementFingerprint != namesBefore
        }
        phaseTiming.verified(walks: verifyWalks, path: "poll")

        switch verification {
        case .confirmed(let milliseconds):
            var appeared: [String] = []
            if let laterRoot = ActionVerifier.snapshotToDescribe(
                confirming: confirmingSnapshot, walks: verifyWalks,
                walkAgain: { try? AccessibilityTreeWalker.snapshotFocusedWindow() }
            )?.rootNode {
                appeared = Array(
                    laterRoot.namedElementFingerprint
                        .subtracting(namesBefore).sorted().prefix(12)
                )
            }
            response["verification"] = [
                "status": "confirmed", "evidence": verifiesRadioSelection
                    ? "resolved radio button changed from unselected to selected" : "named elements changed",
                "milliseconds": milliseconds, "appeared": appeared
            ]
            response["ok"] = true
            audit(request, dryRun: dryRun, kernel: described.decision, outcome: "confirmed", startedAt: startedAt)
        case .windowGone(let milliseconds):
            if verifiesRadioSelection {
                response["verification"] = ["status": "notObserved", "milliseconds": milliseconds]
                response["ok"] = false
                response["error"] = "notVerified"
                audit(request, dryRun: dryRun, kernel: described.decision, outcome: "notObserved", startedAt: startedAt)
                return response
            }
            response["verification"] = [
                "status": "confirmed", "evidence": "the focused window closed",
                "milliseconds": milliseconds, "appeared": [String]()
            ]
            response["ok"] = true
            audit(request, dryRun: dryRun, kernel: described.decision, outcome: "confirmed", startedAt: startedAt)
        case .notObserved(let milliseconds):
            response["verification"] = [
                "status": "notObserved", "milliseconds": milliseconds, "appeared": [String]()
            ]
            if request.verb == .type {
                response["ok"] = true
                response["verificationNote"] =
                    "the field read back the text; the window's named elements did not change"
            } else {
                response["ok"] = false
                response["error"] = "notVerified"
            }
            audit(request, dryRun: dryRun, kernel: described.decision, outcome: "notObserved", startedAt: startedAt)
        case .couldNotReadWindow:
            response["verification"] = ["status": "couldNotReadWindow"]
            response["ok"] = false
            response["error"] = "notVerified"
            audit(request, dryRun: dryRun, kernel: described.decision, outcome: "couldNotReadWindow", startedAt: startedAt)
        }

        return response
    }

    // MARK: menu / menus

    // Menu reads report `menuMilliseconds`, not `walkMilliseconds`, so they
    // don't skew the per-app walk median.

    /// The frontmost app and its menu bar, or nil with the refusal already written.
    private func menuBar(
        for request: HarnessRequest,
        dryRun: Bool,
        startedAt: Date,
        into response: inout [String: Any]
    ) -> (application: NSRunningApplication, bar: AccessibilityMenu.Node)? {

        func fail(_ code: String, _ message: String) {
            response["ok"] = false
            response["error"] = code
            response["message"] = message
            audit(request, dryRun: dryRun, kernel: "n/a", outcome: code, startedAt: startedAt)
        }

        // The guard and the menu bar come from one frontmost read, so they agree.
        let frontmostRead = AccessibilityTreeWalker.frontmost()
        guard let application = frontmostRead.application else {
            fail("noFrontmostApplication", "nothing is frontmost")
            return nil
        }
        // A locked screen makes loginwindow frontmost.
        guard !LockScreenGuard.isLockScreen(application.bundleIdentifier) else {
            fail("screenIsLocked", "the screen is locked — there is no menu bar of the user's to read")
            return nil
        }
        if let refusal = frontmostChangedRefusal(
            request, name: application.localizedName, bundleIdentifier: application.bundleIdentifier,
            dryRun: dryRun, startedAt: startedAt
        ) {
            response.merge(refusal) { _, new in new }
            return nil
        }
        response["application"] = application.localizedName ?? "unknown"
        response["bundleIdentifier"] = application.bundleIdentifier ?? "unknown"
        response["frontmostSource"] = frontmostRead.source.rawValue

        guard let bar = AccessibilityMenu.menuBarNode(for: application) else {
            fail("noMenuBar", "the application publishes no AXMenuBar")
            return nil
        }
        return (application, bar)
    }

    private static func menuResolutionFailure(
        _ resolution: AccessibilityMenu.Resolution
    ) -> (code: String, payload: [String: Any])? {
        switch resolution {
        case .resolved:
            return nil
        case .notFound(let atStep, let step, let available):
            return ("notFound", [
                "status": "notFound",
                "atStep": atStep,
                "step": step,
                // List what was at the failed level, so a typo can be told from a missing item.
                "available": available.map { UntrustedText($0).forDisplay }
            ])
        case .ambiguous(let atStep, let step, let matchCount):
            return ("ambiguous", [
                "status": "ambiguous", "atStep": atStep, "step": step, "matchCount": matchCount
            ])
        case .emptyPath:
            return ("missingField", ["status": "emptyPath"])
        }
    }

    static let maximumSubmenuLabelsListed = 5

    private func menuResponse(_ request: HarnessRequest, dryRun: Bool, startedAt: Date) -> [String: Any] {
        var response: [String: Any] = [
            "dryRun": dryRun, "confirmed": request.confirmed, "path": request.path
        ]
        guard let (application, bar) = menuBar(
            for: request, dryRun: dryRun, startedAt: startedAt, into: &response
        ) else { return response }

        let resolveStartedAt = Date()
        let (node, resolution) = AccessibilityMenu.resolveNode(
            path: request.path, from: bar, children: AccessibilityMenu.liveChildren
        )
        response["menuMilliseconds"] = Int(Date().timeIntervalSince(resolveStartedAt) * 1000)

        if let failure = Self.menuResolutionFailure(resolution) {
            response["resolution"] = failure.payload
            response["ok"] = false
            response["error"] = failure.code
            audit(request, dryRun: dryRun, kernel: "n/a", outcome: failure.code, startedAt: startedAt)
            return response
        }
        guard let node else {
            response["ok"] = false
            response["error"] = "notFound"
            audit(request, dryRun: dryRun, kernel: "n/a", outcome: "notFound", startedAt: startedAt)
            return response
        }

        let resolvedNode = AccessibilityMenu.elementNode(for: node)
        // Pressing a submenu parent opens a menu with no way back out, so it is
        // refused and its items are listed instead.
        if let childLabels = AccessibilityMenu.submenuChildLabels(of: node, children: AccessibilityMenu.liveChildren) {
            response["resolution"] = [
                "status": "targetIsSubmenu", "matchCount": 1, "hasSubmenu": true,
                "available": childLabels.prefix(Self.maximumSubmenuLabelsListed).map { UntrustedText($0).forDisplay }
            ]
            response["ok"] = false
            response["error"] = "targetIsSubmenu"
            response["message"] = "\(request.path.joined(separator: " > ")) has a submenu; name a leaf item, e.g. "
                + "\(request.path.joined(separator: " > ")) > \(childLabels.first ?? "<unlabelled>")"
            audit(request, dryRun: dryRun, kernel: "n/a", outcome: "targetIsSubmenu", startedAt: startedAt)
            return response
        }
        response["resolution"] = [
            "status": "resolved", "matchCount": 1,
            "enabled": node.isEnabled,
            "hasSubmenu": false,
            "shortcut": (node.shortcut ?? NSNull()) as Any
        ]
        response["resolved"] = Self.summarise(resolvedNode)

        let intent = ElementActionIntent(role: nil, title: node.label ?? "", action: .menu)
        let decision = applyAppPolicy(
            to: ActionSafetyKernel.evaluate(
                intent: intent,
                resolvedNode: resolvedNode,
                matchCount: 1,
                // Closed menu items have no on-screen frame; frame checks don't apply.
                visibleBounds: .infinite,
                menuItemEnabled: node.isEnabled
            ),
            bundleIdentifier: application.bundleIdentifier, into: &response
        )
        let described = HarnessPolicy.describe(decision)
        let gated = gate(decision, request: request, appName: application.localizedName,
                         bundleIdentifier: application.bundleIdentifier, dryRun: dryRun,
                         bindingSubject: ActionBinding.Subject(
                            targetElement: resolvedNode.accessibilityElement, processIdentifier: application.processIdentifier
                         ),
                         into: &response)

        guard gated.executable else {
            response["ok"] = false
            response["error"] = gated.outcome
            audit(request, dryRun: dryRun, kernel: described.decision, outcome: gated.outcome, startedAt: startedAt)
            return response
        }

        guard !dryRun else {
            response["ok"] = true
            response["performed"] = ["status": "skipped", "reason": "dry run — nothing was performed"]
            audit(request, dryRun: dryRun, kernel: described.decision, outcome: "dryRun", startedAt: startedAt)
            return response
        }

        guard let element = resolvedNode.accessibilityElement else {
            response["ok"] = false
            response["error"] = "noLiveElement"
            audit(request, dryRun: dryRun, kernel: described.decision, outcome: "noLiveElement", startedAt: startedAt)
            return response
        }

        // Two baselines: a new window with the same names only shows in the count.
        let windowsBefore = AccessibilityMenu.windowCount(for: application)
        let namesBefore = (try? AccessibilityTreeWalker.snapshotFocusedWindow())?
            .rootNode.map(\.namedElementFingerprint)
        response["windowsBefore"] = (windowsBefore ?? NSNull()) as Any

        // Menu items can be pressed with the menu closed.
        phaseTiming.actionStarting()
        let result = AccessibilityActionPerformer.perform(kAXPressAction, on: element)
        phaseTiming.actionReturned()
        response["performed"] = [
            "status": result.error == .success ? "sent" : "failed",
            "axErrorRawValue": result.error.rawValue,
            "milliseconds": result.milliseconds,
            "hasSubmenu": false
        ]
        guard result.error == .success else {
            response["ok"] = false
            response["error"] = "performFailed"
            audit(request, dryRun: dryRun, kernel: described.decision, outcome: "performFailed", startedAt: startedAt)
            return response
        }

        let windowCountMoved = {
            if let windowsBefore, AccessibilityMenu.windowCount(for: application) != windowsBefore { return true }
            return false
        }
        let (verification, verifyWalks) = ActionVerifier.pollCountingWindowsFirst(
            locate: AccessibilityTreeWalker.focusedWindowTarget,
            windowCountMoved: windowCountMoved,
            walk: { try AccessibilityTreeWalker.snapshotFocusedWindow($0) },
            hadFocusedWindowBefore: namesBefore != nil
        ) { laterSnapshot in
            if windowCountMoved() { return true }
            guard let laterRoot = laterSnapshot.rootNode, let namesBefore else { return false }
            return laterRoot.namedElementFingerprint != namesBefore
        }
        phaseTiming.verified(walks: verifyWalks, path: "poll")

        switch verification {
        case .confirmed(let milliseconds):
            let windowsAfter = AccessibilityMenu.windowCount(for: application)
            response["verification"] = [
                "status": "confirmed",
                "evidence": windowsBefore != nil && windowsAfter != windowsBefore
                    ? "the window count changed" : "named elements changed",
                "milliseconds": milliseconds,
                "windowsAfter": (windowsAfter ?? NSNull()) as Any
            ]
            response["ok"] = true
            audit(request, dryRun: dryRun, kernel: described.decision, outcome: "confirmed", startedAt: startedAt)
        case .windowGone(let milliseconds):
            response["verification"] = [
                "status": "confirmed",
                "evidence": "the focused window closed",
                "milliseconds": milliseconds,
                "appeared": [String](),
                "windowsAfter": (AccessibilityMenu.windowCount(for: application) ?? NSNull()) as Any
            ]
            response["ok"] = true
            audit(request, dryRun: dryRun, kernel: described.decision, outcome: "confirmed", startedAt: startedAt)
        case .notObserved(let milliseconds):
            response["verification"] = [
                "status": "notObserved",
                "milliseconds": milliseconds,
                "windowsAfter": (AccessibilityMenu.windowCount(for: application) ?? NSNull()) as Any
            ]
            response["ok"] = false
            response["error"] = "notVerified"
            audit(request, dryRun: dryRun, kernel: described.decision, outcome: "notObserved", startedAt: startedAt)
        case .couldNotReadWindow:
            response["verification"] = ["status": "couldNotReadWindow"]
            response["ok"] = false
            response["error"] = "notVerified"
            audit(request, dryRun: dryRun, kernel: described.decision, outcome: "couldNotReadWindow", startedAt: startedAt)
        }
        return response
    }

    /// What this app can currently do, from its menu bar.
    private func menusResponse(_ request: HarnessRequest, dryRun: Bool, startedAt: Date) -> [String: Any] {
        var response: [String: Any] = ["pathPrefix": request.path]
        guard let (_, bar) = menuBar(
            for: request, dryRun: dryRun, startedAt: startedAt, into: &response
        ) else { return response }

        // Resolve the prefix first, then list from there.
        var startNode = bar
        if !request.path.isEmpty {
            let (node, resolution) = AccessibilityMenu.resolveNode(
                path: request.path, from: bar, children: AccessibilityMenu.liveChildren
            )
            if let failure = Self.menuResolutionFailure(resolution) {
                response["resolution"] = failure.payload
                response["ok"] = false
                response["error"] = failure.code
                audit(request, dryRun: dryRun, kernel: "n/a", outcome: failure.code, startedAt: startedAt)
                return response
            }
            guard let node else {
                response["ok"] = false
                response["error"] = "notFound"
                audit(request, dryRun: dryRun, kernel: "n/a", outcome: "notFound", startedAt: startedAt)
                return response
            }
            startNode = node
        }

        let listing = AccessibilityMenu.list(
            from: startNode,
            pathSoFar: request.path,
            children: AccessibilityMenu.liveChildren,
            deadline: Date().addingTimeInterval(AccessibilityMenu.listingTimeLimitInSeconds)
        )

        if !listing.stopReasons.isEmpty {
            response["warning"] = "THESE COUNTS ARE A FLOOR, NOT A MEASUREMENT — the listing stopped early: "
                + listing.stopReasons.joined(separator: ", ")
        }
        response["listingStopReasons"] = listing.stopReasons
        response["menuMilliseconds"] = listing.milliseconds
        response["itemCount"] = listing.items.count
        response["enabledCount"] = listing.items.filter(\.isEnabled).count
        response["withShortcutCount"] = listing.items.filter { $0.shortcut != nil }.count
        // Paths are raw so they can be sent straight back to `menu`.
        response["items"] = listing.items.map {
            [
                "path": $0.path,
                "role": $0.role,
                "enabled": $0.isEnabled,
                "shortcut": $0.shortcut ?? NSNull(),
                "hasSubmenu": $0.hasSubmenu,
                "marked": $0.isMarked
            ] as [String: Any]
        }
        response["ok"] = true
        audit(request, dryRun: dryRun, kernel: "n/a", outcome: "ok", startedAt: startedAt)
        return response
    }

    // MARK: windows / focus

    /// The named app, or the frontmost. Nil with the refusal already written.
    private func targetApplication(
        for request: HarnessRequest,
        dryRun: Bool,
        startedAt: Date,
        into response: inout [String: Any]
    ) -> NSRunningApplication? {

        func fail(_ code: String, _ message: String, extra: [String: Any] = [:]) {
            response["ok"] = false
            response["error"] = code
            response["message"] = message
            for (key, value) in extra { response[key] = value }
            audit(request, dryRun: dryRun, kernel: "n/a", outcome: code, startedAt: startedAt)
        }
        func unlessHarnessItself(_ application: NSRunningApplication) -> NSRunningApplication? {
            guard Self.isHarnessItself(bundleIdentifier: application.bundleIdentifier) else { return application }
            fail("targetIsHarnessItself", Self.harnessItselfMessage)
            return nil
        }

        guard !LockScreenGuard.isLockScreen(Self.frontmostBundleIdentifier()) else {
            fail("screenIsLocked", "the screen is locked — there are no windows of the user's to read or raise")
            return nil
        }

        let candidates = AccessibilityWindows.runningApplications()

        guard let query = request.app else {
            guard let frontmost = AccessibilityTreeWalker.focusedApplication() else {
                fail("noFrontmostApplication", "nothing is frontmost")
                return nil
            }
            return unlessHarnessItself(frontmost)
        }

        switch AccessibilityWindows.matchApplication(query, among: candidates.map(\.candidate)) {
        case .resolved(let index, let tier):
            response["applicationMatchedOn"] = tier.rawValue
            return unlessHarnessItself(candidates[index].application)
        case .notFound(let available):
            fail(
                "notFound",
                "no running application matches \(UntrustedText(query).forDisplay)",
                extra: ["available": available.map { UntrustedText($0).forDisplay }]
            )
            return nil
        case .ambiguous(let matchCount, let tier):
            fail(
                "ambiguous",
                "\(matchCount) running applications match \(UntrustedText(query).forDisplay) on \(tier.rawValue)",
                extra: ["matchCount": matchCount]
            )
            return nil
        }
    }

    /// One running app, from `NSWorkspace` only.
    private static func summariseApplication(
        _ candidate: AccessibilityWindows.ApplicationCandidate
    ) -> [String: Any] {
        [
            "name": (candidate.localizedName ?? NSNull()) as Any,
            "bundleIdentifier": (candidate.bundleIdentifier ?? NSNull()) as Any,
            "active": candidate.isActive,
            "hidden": candidate.isHidden
        ]
    }

    private static func summariseWindow(
        _ candidate: AccessibilityWindows.WindowCandidate
    ) -> [String: Any] {
        var entry: [String: Any] = [
            "title": (candidate.title?.raw ?? NSNull()) as Any,
            "titleIsPlausibleLabel": candidate.title?.isPlausibleControlLabel ?? false,
            "role": candidate.role,
            "subrole": (candidate.subrole ?? NSNull()) as Any,
            "main": candidate.isMain,
            "minimized": candidate.isMinimized,
            "actions": candidate.publishedActionNames
        ]
        Self.attachFrame(candidate.frameInAppKitCoordinates, to: &entry)
        return entry
    }

    private func windowsResponse(_ request: HarnessRequest, dryRun: Bool, startedAt: Date) -> [String: Any] {
        var response: [String: Any] = [:]
        guard let application = targetApplication(
            for: request, dryRun: dryRun, startedAt: startedAt, into: &response
        ) else { return response }

        response["application"] = application.localizedName ?? "unknown"
        response["bundleIdentifier"] = application.bundleIdentifier ?? "unknown"

        // The window list only covers the current Space, so check what is in front.
        let frontmost = AccessibilityTreeWalker.focusedApplication()
        if let refusal = frontmostChangedRefusal(
            request, name: frontmost?.localizedName, bundleIdentifier: frontmost?.bundleIdentifier,
            dryRun: dryRun, startedAt: startedAt
        ) { return response.merging(refusal) { _, new in new } }

        let readStartedAt = Date()
        let read = AccessibilityWindows.liveWindows(for: application)
        response["focusMilliseconds"] = Int(Date().timeIntervalSince(readStartedAt) * 1000)

        response["windowCount"] = read.windows.count
        response["windows"] = read.windows.map { Self.summariseWindow($0.candidate) }
        response["applications"] = AccessibilityWindows.runningApplications()
            .map { Self.summariseApplication($0.candidate) }

        // Distinguishes "no windows" from "the app did not answer".
        response["windowListRead"] = read.readSucceeded ? "ok" : "failed"
        response["windowListErrorRawValue"] = read.error.rawValue
        // The window list is Space-scoped, so zero windows is not conclusive.
        if read.readSucceeded, read.windows.isEmpty, frontmost?.processIdentifier != application.processIdentifier {
            response["warning"] = "ZERO IS NOT A MEASUREMENT — \(application.localizedName ?? "this app") "
                + "is not the active application, and kAXWindows only lists windows on the active Space. "
                + "Focus the app and read again before concluding it has no windows."
        }
        if !read.readSucceeded {
            response["warning"] = "WINDOW COUNT IS NOT A MEASUREMENT — "
                + "kAXWindows failed with AXError \(read.error.rawValue); the list below is empty "
                + "because the read did not answer, not because the app has no windows"
        }
        response["ok"] = read.readSucceeded
        if !read.readSucceeded { response["error"] = "windowListUnreadable" }
        audit(
            request, dryRun: dryRun, kernel: "n/a",
            outcome: read.readSucceeded ? "ok" : "windowListUnreadable", startedAt: startedAt
        )
        return response
    }

    private func focusResponse(_ request: HarnessRequest, dryRun: Bool, startedAt: Date) -> [String: Any] {
        var response: [String: Any] = [
            "dryRun": dryRun, "confirmed": request.confirmed,
            "app": (request.app ?? NSNull()) as Any,
            "title": request.title.isEmpty ? NSNull() : request.title
        ]

        // Captured before anything moves, so the user can go back.
        if let previous = AccessibilityWindows.previousApplication() {
            response["previousApplication"] = [
                "name": (previous.name ?? NSNull()) as Any,
                "bundleIdentifier": (previous.bundleIdentifier ?? NSNull()) as Any
            ]
        }

        guard let application = targetApplication(
            for: request, dryRun: dryRun, startedAt: startedAt, into: &response
        ) else { return response }

        response["application"] = application.localizedName ?? "unknown"
        response["bundleIdentifier"] = application.bundleIdentifier ?? "unknown"

        // Judged before reading windows: reading another Space's windows activates the app.
        let appDecision = applyAppPolicy(to: .allow, bundleIdentifier: application.bundleIdentifier, into: &response)
        let appGate = gate(appDecision, request: request, appName: application.localizedName,
                           bundleIdentifier: application.bundleIdentifier, dryRun: dryRun, into: &response)
        guard appGate.executable else {
            response["ok"] = false
            response["error"] = appGate.outcome
            audit(request, dryRun: dryRun, kernel: appGate.decision, outcome: appGate.outcome, startedAt: startedAt)
            return response
        }

        let readStartedAt = Date()
        var read = AccessibilityWindows.liveWindows(for: application)

        // Windows on another Space are invisible until the app is activated.
        if !request.title.isEmpty, read.windows.isEmpty, !application.isActive {
            let attempt = AccessibilityWindows.activateAndWaitForWindows(application)
            read = attempt.read
            response["activatedToReadWindows"] = [
                "activated": attempt.activated,
                "milliseconds": attempt.milliseconds,
                "windowsThenVisible": attempt.read.windows.count
            ]
        }
        response["focusMilliseconds"] = Int(Date().timeIntervalSince(readStartedAt) * 1000)
        response["windowCount"] = read.windows.count
        response["windowListRead"] = read.readSucceeded ? "ok" : "failed"

        // A failed read is not a missing window.
        if !request.title.isEmpty, !read.readSucceeded {
            response["ok"] = false
            response["error"] = "windowListUnreadable"
            response["message"] = "kAXWindows failed with AXError \(read.error.rawValue) — "
                + "cannot tell whether that window exists"
            audit(request, dryRun: dryRun, kernel: "n/a", outcome: "windowListUnreadable", startedAt: startedAt)
            return response
        }

        var resolvedWindow: (element: AXUIElement, candidate: AccessibilityWindows.WindowCandidate)?
        var matchCount = 1
        var kernelTitle: UntrustedText?

        if !request.title.isEmpty {
            switch AccessibilityWindows.matchWindow(
                title: request.title, nearPoint: request.nearPoint,
                among: read.windows.map(\.candidate)
            ) {
            case .resolved(let index):
                resolvedWindow = read.windows[index]
                kernelTitle = read.windows[index].candidate.title
                response["resolution"] = [
                    "status": "resolved", "matchCount": 1,
                    "title": (read.windows[index].candidate.title?.raw ?? NSNull()) as Any
                ]
            case .notFound(let available):
                response["resolution"] = [
                    "status": "notFound",
                    "available": available.map { UntrustedText($0).forDisplay }
                ]
                response["ok"] = false
                response["error"] = "notFound"
                attachFocusEscalation(
                    to: &response, request: request,
                    windows: read.windows.map(\.candidate), application: application
                )
                audit(request, dryRun: dryRun, kernel: "n/a", outcome: "notFound", startedAt: startedAt)
                return response
            case .ambiguous(let count):
                matchCount = count
                kernelTitle = UntrustedText(request.title)
                response["resolution"] = ["status": "ambiguous", "matchCount": count]
            }
        }

        let decision = applyAppPolicy(
            to: ActionSafetyKernel.evaluateFocus(windowTitle: kernelTitle, matchCount: matchCount),
            bundleIdentifier: application.bundleIdentifier, into: &response
        )
        let described = HarnessPolicy.describe(decision)
        let gated = gate(decision, request: request, appName: application.localizedName,
                         bundleIdentifier: application.bundleIdentifier, dryRun: dryRun, into: &response)

        guard gated.executable else {
            response["ok"] = false
            response["error"] = gated.outcome
            if matchCount != 1 {
                attachFocusEscalation(
                    to: &response, request: request,
                    windows: read.windows.map(\.candidate), application: application
                )
            }
            audit(request, dryRun: dryRun, kernel: described.decision,
                  outcome: described.decision == "refuse" ? "kernelRefused" : "confirmationRequired",
                  startedAt: startedAt)
            return response
        }

        guard !dryRun else {
            response["ok"] = true
            response["performed"] = ["status": "skipped", "reason": "dry run — nothing was performed"]
            audit(request, dryRun: dryRun, kernel: described.decision, outcome: "dryRun", startedAt: startedAt)
            return response
        }

        phaseTiming.actionStarting()
        let outcome = AccessibilityWindows.focus(application: application, window: resolvedWindow)
        phaseTiming.actedThenVerified(actMilliseconds: outcome.actMilliseconds,
                                      walks: outcome.observationPolls, path: outcome.observedVia)

        // Each step is reported separately.
        response["performed"] = [
            "unminimized": outcome.unminimized,
            "unminimizeErrorRawValue": (outcome.unminimizeErrorRawValue.map { Int($0) } ?? NSNull()) as Any,
            "raisePublished": outcome.raisePublished,
            "axErrorRawValue": (outcome.raiseErrorRawValue.map { Int($0) } ?? NSNull()) as Any,
            "milliseconds": (outcome.raiseMilliseconds ?? NSNull()) as Any,
            "activated": outcome.activated
        ]
        response["verification"] = [
            "status": outcome.observed ? "confirmed" : "notObserved",
            "readBackMain": (outcome.readBackMain ?? NSNull()) as Any,
            "observed": outcome.observed,
            "milliseconds": outcome.observedMilliseconds,
            "observedApplication": (outcome.observedApplication ?? NSNull()) as Any,
            "observedVia": (outcome.observedVia ?? NSNull()) as Any,
            "observedWindowTitle": (outcome.observedWindowTitle?.raw ?? NSNull()) as Any
        ]

        response["ok"] = outcome.observed
        if !outcome.observed { response["error"] = "notVerified" }
        audit(request, dryRun: dryRun, kernel: described.decision,
              outcome: outcome.observed ? "confirmed" : "notObserved", startedAt: startedAt)
        return response
    }

    // MARK: launch

    private func launchResponse(_ request: HarnessRequest, dryRun: Bool, startedAt: Date) -> [String: Any] {
        var response: [String: Any] = [
            "dryRun": dryRun, "confirmed": request.confirmed,
            "app": (request.app ?? NSNull()) as Any
        ]
        func fail(_ code: String, _ message: String, kernel: String = "n/a") -> [String: Any] {
            response["ok"] = false
            response["error"] = code
            response["message"] = message
            audit(request, dryRun: dryRun, kernel: kernel, outcome: code, startedAt: startedAt)
            return response
        }

        guard let query = request.app else { return fail("missingField", "missing required field \"app\"") }

        guard !LockScreenGuard.isLockScreen(Self.frontmostBundleIdentifier()) else {
            return fail("screenIsLocked", "the screen is locked — an application cannot be launched into it")
        }

        let url: URL
        let bundleIdentifier: String
        switch ApplicationLauncher.resolve(query) {
        case .resolved(let resolvedURL, let resolvedIdentifier):
            url = resolvedURL
            bundleIdentifier = resolvedIdentifier
        case .notFound:
            return fail("notFound", "no installed application matches \(UntrustedText(query).forDisplay) "
                + "by bundle identifier or exact name in "
                + ApplicationLauncher.searchDirectories.map(\.path).joined(separator: ", "))
        case .ambiguous(let candidates):
            response["candidates"] = candidates.map(\.path)
            return fail("ambiguous", "\(candidates.count) installed applications match \(UntrustedText(query).forDisplay)")
        }
        guard !Self.isHarnessItself(bundleIdentifier: bundleIdentifier) else {
            return fail("targetIsHarnessItself", Self.harnessItselfMessage)
        }
        response["application"] = url.deletingPathExtension().lastPathComponent
        response["bundleIdentifier"] = bundleIdentifier
        response["path"] = url.path

        let decision = applyAppPolicy(
            to: ActionSafetyKernel.evaluateLaunch(bundleIdentifier: bundleIdentifier),
            bundleIdentifier: bundleIdentifier, into: &response
        )
        let described = HarnessPolicy.describe(decision)
        let gated = gate(decision, request: request, appName: url.deletingPathExtension().lastPathComponent,
                         bundleIdentifier: bundleIdentifier, dryRun: dryRun, into: &response)
        guard gated.executable else {
            response["ok"] = false
            response["error"] = gated.outcome
            if response["message"] == nil { response["message"] = gated.note ?? gated.outcome }
            audit(request, dryRun: dryRun, kernel: described.decision, outcome: gated.outcome, startedAt: startedAt)
            return response
        }

        response["alreadyRunning"] = !NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleIdentifier).isEmpty

        guard !dryRun else {
            response["ok"] = true
            response["performed"] = ["status": "skipped", "reason": "dry run — nothing was launched"]
            audit(request, dryRun: dryRun, kernel: described.decision, outcome: "dryRun", startedAt: startedAt)
            return response
        }

        phaseTiming.actionStarting()
        let outcome = ApplicationLauncher.launchAndWait(url)
        if let processMilliseconds = outcome.processMilliseconds {
            phaseTiming.actedThenVerified(actMilliseconds: processMilliseconds,
                                          walks: outcome.readinessPolls, path: nil)
        } else {
            phaseTiming.actionReturned()
        }
        response["launchMilliseconds"] = elapsedMilliseconds(since: startedAt)
        response["launch"] = [
            "processMilliseconds": (outcome.processMilliseconds ?? NSNull()) as Any,
            "frontmostMilliseconds": (outcome.frontmostMilliseconds ?? NSNull()) as Any,
            "windowMilliseconds": (outcome.windowMilliseconds ?? NSNull()) as Any,
            "lastFrontmostError": (outcome.lastFrontmostError.map { Int($0) } ?? NSNull()) as Any,
            "lastWindowError": (outcome.lastWindowError.map { Int($0) } ?? NSNull()) as Any
        ]

        if let launchError = outcome.launchError {
            return fail("launchFailed", launchError, kernel: described.decision)
        }

        response["status"] = outcome.status.rawValue
        switch outcome.status {
        case .ready, .frontmostNoWindow:
            response["ok"] = true
            audit(request, dryRun: dryRun, kernel: described.decision,
                  outcome: outcome.status.rawValue, startedAt: startedAt)
            return response
        case .notReady:
            return fail(
                "launchNotReady",
                "\(bundleIdentifier) never reported AXFrontmost true within "
                    + "\(ApplicationLauncher.launchReadinessDeadlineInSeconds) s"
                    + (outcome.windowMilliseconds != nil ? " — it has a window, so it may have launched behind another app" : ""),
                kernel: described.decision
            )
        }
    }

    // MARK: look / escalation

    private struct EscalationPlan {
        let tier: EscalationLadder.Tier
        let reason: String
        let region: CGRect
        /// Which resolver the candidates (and their points) belong to: a separating
        /// point is only valid within the set it was computed from.
        let resolver: String
        let candidates: [AccessibilityElementNode]
        /// The one app a capture may photograph; nil means nothing is captured.
        let application: NSRunningApplication?
    }

    /// The display holding the window, else the cursor, else the first one.
    private static func fallbackDisplayFrame(
        forWindowFrame windowFrame: CGRect?,
        among displays: [EscalationLadder.DisplayInfo]
    ) -> CGRect? {
        if let windowFrame, windowFrame.width > 0, windowFrame.height > 0,
           let display = EscalationLadder.display(holding: windowFrame, among: displays) {
            return display.appKitFrame
        }
        let cursor = cursorLocationInAppKitCoordinates()
        return displays.first(where: { display in cursor.map { display.appKitFrame.contains($0) } ?? false })?.appKitFrame
            ?? displays.first?.appKitFrame
    }

    /// The cursor in AppKit coordinates without touching the main thread.
    nonisolated static func cursorLocationInAppKitCoordinates() -> CGPoint? {
        guard let topLeft = CGEvent(source: nil)?.location else { return nil }
        return CGPoint(x: topLeft.x, y: CGDisplayBounds(CGMainDisplayID()).height - topLeft.y)
    }

    private func escalationPlan(
        forcedTier: EscalationLadder.Tier?,
        title: String,
        role: String?,
        rootNode: AccessibilityElementNode?,
        application: NSRunningApplication?
    ) -> EscalationPlan? {
        let displays = EscalationLadder.displays()
        let allNodes = rootNode?.flattenedDescendants() ?? []
        let candidates = (rootNode.map { root in
            title.isEmpty ? [] : EscalationLadder.namedCandidates(in: root, title: title, role: role)
        }) ?? []

        let choice = EscalationLadder.chooseTier(
            forcedTier: forcedTier,
            candidateFrames: candidates.map(\.frameInAppKitCoordinates),
            windowFrame: rootNode?.frameInAppKitCoordinates,
            windowActionableCount: allNodes.filter(\.isActionable).count
        )

        let region: CGRect?
        switch choice.tier {
        case .element:
            region = EscalationLadder.region(forCandidateFrames: candidates.map(\.frameInAppKitCoordinates))
        case .window:
            region = rootNode?.frameInAppKitCoordinates
        case .display, .none:
            region = Self.fallbackDisplayFrame(
                forWindowFrame: rootNode?.frameInAppKitCoordinates, among: displays
            )
        }
        guard let region, region.width > 0, region.height > 0 else { return nil }

        let inRegion = allNodes.filter { $0.frameInAppKitCoordinates.intersects(region) }
        return EscalationPlan(
            tier: choice.tier,
            reason: choice.reason,
            region: region,
            resolver: "elementName",
            candidates: choice.tier == .element ? candidates : inRegion.filter(\.isActionable),
            application: application
        )
    }

    /// Caps the candidate list (the separating-point search is quadratic).
    static let maximumCandidates = 40

    private func attachFocusEscalation(
        to response: inout [String: Any],
        request: HarnessRequest,
        windows: [AccessibilityWindows.WindowCandidate],
        application: NSRunningApplication
    ) {
        guard let plan = windowEscalationPlan(
            title: request.title, windows: windows, application: application
        ) else { return }
        let result = escalationPayload(plan: plan, capture: request.escalate)
        var payload = result.payload
        payload["available"] = true
        if !request.escalate {
            payload["hint"] = "re-issue with \"escalate\": true for an image and candidate points"
        }
        response["escalation"] = payload
    }

    /// The ladder built from an app's window list, which is what `focus` resolves against.
    private func windowEscalationPlan(
        title: String,
        windows: [AccessibilityWindows.WindowCandidate],
        application: NSRunningApplication
    ) -> EscalationPlan? {
        func node(_ candidate: AccessibilityWindows.WindowCandidate) -> AccessibilityElementNode {
            AccessibilityElementNode(
                role: candidate.role, subrole: candidate.subrole,
                title: candidate.title?.raw, value: nil,
                frameInAppKitCoordinates: candidate.frameInAppKitCoordinates,
                depth: 0, children: [],
                publishedActionNames: candidate.publishedActionNames
            )
        }

        let lowercased = title.lowercased()
        let matching = windows.filter { $0.title?.raw.lowercased() == lowercased }
        let shown = matching.isEmpty ? windows : matching
        let candidates = shown.map(node)
        guard let region = EscalationLadder.region(
            forCandidateFrames: candidates.map(\.frameInAppKitCoordinates)
        ) else { return nil }

        return EscalationPlan(
            tier: .element,
            reason: matching.isEmpty
                ? "no window matched that title; the region is the union of the app's \(windows.count) window(s)"
                : "\(matching.count) window(s) matched that title; the region is the union of their frames padded",
            region: region,
            resolver: "windowTitle",
            candidates: candidates,
            application: application
        )
    }

    /// Candidates with a point that picks each out, or none. Named ones first.
    private static func summariseCandidates(_ all: [AccessibilityElementNode]) -> [[String: Any]] {
        let named = all.filter { $0.displayName?.isPlausibleControlLabel == true }
        let anonymous = all.filter { $0.displayName?.isPlausibleControlLabel != true }
        let nodes = Array((named + anonymous).prefix(maximumCandidates))
        let frames = nodes.map(\.frameInAppKitCoordinates)
        return nodes.indices.map { index in
            var entry = summarise(nodes[index])
            entry["index"] = index
            let point = EscalationLadder.separatingPoint(forCandidateAt: index, among: frames)
            if let point {
                let (json, invalid) = pointJSON(point)
                entry["suggestedPoint"] = json
                if invalid { entry["pointInvalid"] = true }
            } else {
                entry["suggestedPoint"] = NSNull()
            }
            // `false` stops a caller re-issuing a point that will come back ambiguous.
            entry["separable"] = point != nil
            return entry
        }
    }

    /// Shared by `look` and the acting verbs' `escalation` block.
    private func escalationPayload(
        plan: EscalationPlan,
        capture: Bool
    ) -> (payload: [String: Any], errorCode: String?) {
        var payload: [String: Any] = [
            "tier": plan.tier.rawValue,
            "reason": plan.reason,
            "resolver": plan.resolver
        ]

        guard capture else {
            // Without `escalate`, only say which rung would be used; a capture costs
            // around 350 ms.
            payload["hint"] = "re-issue with \"escalate\": true for an image and candidate points"
            return (payload, nil)
        }

        Self.attachFrame(plan.region, to: &payload, key: "region")
        // Always the true total, even when the list is shorter.
        payload["candidateCount"] = plan.candidates.count
        let listed = Self.summariseCandidates(plan.candidates)
        payload["candidates"] = listed
        if listed.count < plan.candidates.count {
            payload["candidatesTruncated"] = true
            payload["warning"] = "THIS LIST IS A FLOOR, NOT A MEASUREMENT — showing \(listed.count) "
                + "of \(plan.candidates.count) candidates, named ones first"
        }

        // Inspect for password fields first; the capture only covers what was inspected.
        guard let application = plan.application else {
            payload["message"] = "no application to restrict the capture to, and a display-wide capture is never taken"
            return (payload, "captureFailed")
        }
        // The per-app policy applies to captures: `refuse` blocks looking too.
        let (verdict, source) = HarnessAppPolicy.verdict(for: application.bundleIdentifier, in: loadedPolicy)
        payload["policy"] = policyBlock(verdict: verdict, source: source, bundleIdentifier: application.bundleIdentifier)
        guard verdict != .refuse else {
            payload["message"] = "app policy refuses \(application.bundleIdentifier ?? "this app") — nothing was photographed"
            return (payload, "policyRefused")
        }
        let inspectStartedAt = Date()
        let inspection = EscalationLadder.inspectForCapture(region: plan.region, of: application)
        payload["inspectMilliseconds"] = Int(Date().timeIntervalSince(inspectStartedAt) * 1000)
        payload["inspectedWindows"] = inspection.windows.count
        payload["secureFieldCheck"] = inspection.incompleteReason ?? "complete"
        let decision = ActionSafetyKernel.evaluateCapture(inspection)
        let described = HarnessPolicy.describe(decision)
        let executable = HarnessPolicy.executableWithoutAHuman(decision)
        payload["kernel"] = [
            "decision": described.decision,
            "reason": (described.reason ?? NSNull()) as Any,
            "executable": executable,
            "note": (described.reason.map { "refused: \($0)" } ?? NSNull()) as Any
        ]
        guard executable else {
            return (payload, "kernelRefused")
        }

        // Nothing to photograph: refuse rather than return a blank image.
        guard inspection.containsDrawableWindow else {
            payload["message"] = "none of this app's windows in the region is a real window (Finder's desktop "
                + "draws nothing in a one-app capture), so the image would be blank"
            return (payload, "applicationNotCapturable")
        }

        let displays = EscalationLadder.displays()
        guard let display = EscalationLadder.display(holding: plan.region, among: displays) else {
            payload["message"] = EscalationLadder.CaptureFailure.regionOffScreen.description
            return (payload, "captureFailed")
        }

        switch EscalationLadder.captureSynchronously(
            region: plan.region, on: display,
            processIdentifier: application.processIdentifier
        ) {
        case .failure(let error):
            payload["message"] = String(describing: error)
            if let failure = error as? EscalationLadder.CaptureFailure,
               case .applicationNotListed = failure {
                return (payload, "applicationNotCapturable")
            }
            return (payload, "captureFailed")

        case .success(let outcome):
            guard let url = EscalationLadder.writeImage(outcome.jpeg) else {
                payload["message"] = "the image could not be written to \(EscalationLadder.imageDirectory.path)"
                return (payload, "captureFailed")
            }
            payload["imagePath"] = url.path
            payload["imageBytes"] = outcome.jpeg.count
            payload["imagePixels"] = ["w": outcome.pixelWidth, "h": outcome.pixelHeight]
            Self.attachFrame(outcome.region, to: &payload, key: "region")
            payload["pointsPerPixel"] = outcome.pixelWidth > 0
                ? outcome.region.width / CGFloat(outcome.pixelWidth) : 0
            payload["captureMilliseconds"] = outcome.milliseconds
            return (payload, nil)
        }
    }

    /// Adds an escalation block under a failed acting verb.
    private func attachEscalation(
        to response: inout [String: Any],
        request: HarnessRequest,
        rootNode: AccessibilityElementNode,
        application: NSRunningApplication?
    ) {
        guard let plan = escalationPlan(
            forcedTier: request.tier, title: request.title, role: request.role, rootNode: rootNode,
            application: application
        ) else { return }

        let result = escalationPayload(plan: plan, capture: request.escalate)
        var block = result.payload
        block["available"] = true
        if let code = result.errorCode { block["error"] = code }
        // Offer the free container-name rung before a picture.
        if block["hint"] != nil, response["error"] as? String == "ambiguous" {
            block["hint"] = "first re-issue with a candidate's \"suggestedWithinNamed\" as \"withinNamed\" "
                + "(free, structural); only if the one you mean has null there, "
                + "re-issue with \"escalate\": true for an image and candidate points"
        }
        response["escalation"] = block
    }

    private func lookResponse(_ request: HarnessRequest, dryRun: Bool, startedAt: Date) -> [String: Any] {
        var response: [String: Any] = [
            "title": request.title.isEmpty ? NSNull() : request.title,
            "requestedTier": (request.tier?.rawValue ?? NSNull()) as Any
        ]

        func fail(_ code: String, _ message: String) -> [String: Any] {
            response["ok"] = false
            response["error"] = code
            response["message"] = message
            audit(request, dryRun: dryRun, kernel: "n/a", outcome: code, startedAt: startedAt)
            return response
        }

        // Never photograph a locked screen.
        guard !LockScreenGuard.isLockScreen(Self.frontmostBundleIdentifier()) else {
            return fail("screenIsLocked", "the screen is locked — there is nothing of the user's to photograph")
        }

        // A failed walk still allows a display capture; the error travels with it.
        var rootNode: AccessibilityElementNode?
        let application: NSRunningApplication?
        do {
            let snapshot = try AccessibilityTreeWalker.snapshotFocusedWindow()
            rootNode = snapshot.rootNode
            application = snapshot.application
            response["application"] = snapshot.applicationName
            response["bundleIdentifier"] = snapshot.bundleIdentifier
            response["frontmostSource"] = snapshot.frontmostSource?.rawValue ?? NSNull()
            response["walkMilliseconds"] = Int(snapshot.walkDurationInSeconds * 1000)
        } catch {
            application = AccessibilityTreeWalker.focusedApplication()
            response["snapshotError"] = Self.errorCode(for: error)
            response["application"] = application?.localizedName ?? "unknown"
            response["bundleIdentifier"] = application?.bundleIdentifier ?? "unknown"
        }

        if let refusal = frontmostChangedRefusal(
            request, name: response["application"] as? String,
            bundleIdentifier: response["bundleIdentifier"] as? String,
            dryRun: dryRun, startedAt: startedAt
        ) { return response.merging(refusal) { _, new in new } }

        guard let plan = escalationPlan(
            forcedTier: request.tier, title: request.title, role: request.role, rootNode: rootNode,
            application: application
        ) else {
            return fail(
                "notFound",
                request.tier == .element
                    ? "nothing matched that name, so there is no element region to crop to"
                    : "no rectangle to capture: neither a window frame nor a display frame was readable"
            )
        }

        let result = escalationPayload(plan: plan, capture: true)
        for (key, value) in result.payload { response[key] = value }
        response["ok"] = result.errorCode == nil
        if let code = result.errorCode { response["error"] = code }
        audit(
            request, dryRun: dryRun,
            kernel: (result.payload["kernel"] as? [String: Any])?["decision"] as? String ?? "n/a",
            outcome: result.errorCode ?? "ok", startedAt: startedAt
        )
        return response
    }

    // MARK: status

    static let statusItemVerificationDeadlineInSeconds = 2.0
    static let statusMenuPressTimeoutInSeconds: Float = 0.5

    private static func summariseStatusItem(_ descriptor: AccessibilityStatusItems.Descriptor) -> [String: Any] {
        var entry: [String: Any] = [
            "owner": [
                "name": (descriptor.ownerName ?? NSNull()) as Any,
                "bundleIdentifier": (descriptor.ownerBundleIdentifier ?? NSNull()) as Any
            ],
            "identifier": (descriptor.identifier ?? NSNull()) as Any,
            "title": (descriptor.title?.raw ?? NSNull()) as Any,
            "description": (descriptor.elementDescription?.raw ?? NSNull()) as Any,
            "value": (descriptor.value?.raw ?? NSNull()) as Any,
            "enabled": descriptor.isEnabled,
            "actions": descriptor.publishedActionNames,
            "hasMenu": descriptor.hasMenu,
            "secure": AccessibilityStatusItems.isSecure(descriptor)
        ]
        Self.attachFrame(descriptor.frameInAppKitCoordinates, to: &entry)
        return entry
    }

    private func refuseIfScreenIsLocked(_ request: HarnessRequest, dryRun: Bool, startedAt: Date,
                                        _ message: String, into response: inout [String: Any]) -> Bool {
        guard LockScreenGuard.isLockScreen(Self.frontmostBundleIdentifier()) else { return false }
        response["ok"] = false
        response["error"] = "screenIsLocked"
        response["message"] = message
        audit(request, dryRun: dryRun, kernel: "n/a", outcome: "screenIsLocked", startedAt: startedAt)
        return true
    }

    /// A process that did not answer is reported, not treated as having no icon.
    private static func attachReadFailures(_ read: AccessibilityStatusItems.ReadAll, to response: inout [String: Any]) {
        response["processesFailedCount"] = read.processesFailed.count
        response["processesFailed"] = read.processesFailed.map {
            ["name": UntrustedText($0.name).forDisplay, "axErrorRawValue": Int($0.axErrorRawValue)] as [String: Any]
        }
        response["childrenFailed"] = read.childrenFailed
        if !read.processesFailed.isEmpty || read.childrenFailed > 0 {
            response["warning"] = "THIS LIST IS A FLOOR, NOT A MEASUREMENT — \(read.processesFailed.count) process(es) "
                + "and \(read.childrenFailed) item(s) did not answer"
        }
    }

    /// Icons are global, so there is no frontmost check.
    private func statusResponse(_ request: HarnessRequest, dryRun: Bool, startedAt: Date) -> [String: Any] {
        var response: [String: Any] = [:]
        if refuseIfScreenIsLocked(request, dryRun: dryRun, startedAt: startedAt,
                                  "the screen is locked — the status items are not the user's", into: &response) { return response }
        let read = AccessibilityStatusItems.readAll()
        audit(request, dryRun: dryRun, kernel: "n/a", outcome: "ok", startedAt: startedAt)
        response["ok"] = true
        response["itemCount"] = read.items.count
        response["processesAsked"] = read.processesAsked
        response["processesAnswered"] = read.processesAnswered
        response["statusMilliseconds"] = read.milliseconds
        response["items"] = read.items.map { Self.summariseStatusItem($0.descriptor) }
        Self.attachReadFailures(read, to: &response)
        return response
    }

    private func statusItemPressResponse(_ request: HarnessRequest, dryRun: Bool, startedAt: Date) -> [String: Any] {
        let query = request.statusItem ?? ""
        var response: [String: Any] = ["dryRun": dryRun, "confirmed": request.confirmed, "statusItem": query]
        if refuseIfScreenIsLocked(request, dryRun: dryRun, startedAt: startedAt,
                                  "the screen is locked — there is no status item of the user's to press", into: &response) { return response }

        let read = AccessibilityStatusItems.readAll()
        response["statusMilliseconds"] = read.milliseconds
        let item: AccessibilityStatusItems.Item
        switch AccessibilityStatusItems.match(query, among: read.items.map(\.descriptor)) {
        case .resolved(let index, let tier):
            item = read.items[index]
            response["resolution"] = ["status": "resolved", "matchedOn": tier.rawValue]
        case .ambiguous(let matchCount, let tier):
            response["resolution"] = ["status": "ambiguous", "matchCount": matchCount, "matchedOn": tier.rawValue]
            response["ok"] = false
            response["error"] = "ambiguous"
            Self.attachReadFailures(read, to: &response)
            audit(request, dryRun: dryRun, kernel: "n/a", outcome: "ambiguous", startedAt: startedAt)
            return response
        case .notFound(let available):
            response["resolution"] = [
                "status": "notFound",
                "available": available.map { UntrustedText($0).forDisplay }
            ]
            response["ok"] = false
            response["error"] = "notFound"
            Self.attachReadFailures(read, to: &response)
            audit(request, dryRun: dryRun, kernel: "n/a", outcome: "notFound", startedAt: startedAt)
            return response
        }
        let descriptor = item.descriptor
        response["item"] = Self.summariseStatusItem(descriptor)
        // Our own status item opens our panel.
        if Self.isHarnessItself(bundleIdentifier: descriptor.ownerBundleIdentifier) {
            response["ok"] = false
            response["error"] = "targetIsHarnessItself"
            response["message"] = Self.harnessItselfMessage
            audit(request, dryRun: dryRun, kernel: "n/a", outcome: "targetIsHarnessItself", startedAt: startedAt)
            return response
        }

        if let expected = request.expectApp,
           !HarnessPolicy.appMatches(expected: expected, bundleIdentifier: descriptor.ownerBundleIdentifier, name: descriptor.ownerName) {
            response["ok"] = false
            response["error"] = "expectAppMismatch"
            response["expectedApp"] = expected
            response["message"] = "the matched status item is owned by "
                + "\(UntrustedText(descriptor.ownerName ?? descriptor.ownerBundleIdentifier ?? "unknown").forDisplay), "
                + "not \(UntrustedText(expected).forDisplay) — nothing was pressed"
            audit(request, dryRun: dryRun, kernel: "n/a", outcome: "expectAppMismatch", startedAt: startedAt)
            return response
        }

        // Password managers' status items are refused like secure fields.
        if AccessibilityStatusItems.isSecure(descriptor) {
            _ = applyAppPolicy(to: .allow, bundleIdentifier: descriptor.ownerBundleIdentifier, into: &response)
            response["kernel"] = [
                "decision": "refuse",
                "reason": ActionSafetyKernel.secureStatusItemRefusalReason,
                "executable": false
            ]
            response["ok"] = false
            response["error"] = "kernelRefused"
            audit(request, dryRun: dryRun, kernel: "refuse", outcome: "kernelRefused", startedAt: startedAt)
            return response
        }

        // An anonymous item is named by its owner.
        let name = descriptor.identifier ?? descriptor.title?.raw ?? descriptor.elementDescription?.raw
            ?? descriptor.ownerName ?? ""
        let resolvedNode = AccessibilityElementNode(
            role: AccessibilityMenu.menuBarItemRole, subrole: nil,
            title: descriptor.title?.raw ?? name, value: descriptor.value?.raw,
            elementDescription: descriptor.elementDescription?.raw,
            frameInAppKitCoordinates: descriptor.frameInAppKitCoordinates,
            depth: 0, children: [],
            publishedActionNames: descriptor.publishedActionNames,
            accessibilityElement: item.element
        )
        let decision = applyAppPolicy(
            to: ActionSafetyKernel.evaluate(
                intent: ElementActionIntent(role: nil, title: name, action: .menu),
                resolvedNode: resolvedNode,
                matchCount: 1,
                // The menu bar may be off-screen in a full-screen Space; pressing still works.
                visibleBounds: .infinite,
                menuItemEnabled: descriptor.isEnabled
            ),
            bundleIdentifier: descriptor.ownerBundleIdentifier, into: &response
        )
        let described = HarnessPolicy.describe(decision)
        let gated = gate(decision, request: request, appName: descriptor.ownerName,
                         bundleIdentifier: descriptor.ownerBundleIdentifier, dryRun: dryRun, into: &response)
        guard gated.executable else {
            response["ok"] = false
            response["error"] = gated.outcome
            audit(request, dryRun: dryRun, kernel: described.decision, outcome: gated.outcome, startedAt: startedAt)
            return response
        }
        guard !dryRun else {
            response["ok"] = true
            response["performed"] = ["status": "skipped", "reason": "dry run — nothing was performed"]
            audit(request, dryRun: dryRun, kernel: described.decision, outcome: "dryRun", startedAt: startedAt)
            return response
        }

        // Four baselines, because each kind of status item changes something different.
        let owner = NSRunningApplication(processIdentifier: descriptor.ownerProcessIdentifier)
        let ownerPid = descriptor.ownerProcessIdentifier
        let windowsBefore = owner.flatMap(AccessibilityMenu.windowCount)
        let childrenBefore = AccessibilityStatusItems.childCount(of: item.element)
        let selectedBefore = AccessibilityStatusItems.isSelected(item.element)
        let ownerWasFrontmost = AccessibilityTreeWalker.frontmost().application?.processIdentifier == ownerPid
        response["windowsBefore"] = (windowsBefore ?? NSNull()) as Any

        // Items with menus don't return until the menu closes, so use a short
        // timeout and let verification decide.
        phaseTiming.actionStarting()
        let result = AccessibilityActionPerformer.perform(
            kAXPressAction, on: item.element,
            timeoutInSeconds: descriptor.hasMenu ? Self.statusMenuPressTimeoutInSeconds
                : AccessibilityActionPerformer.actionTimeoutInSeconds
        )
        phaseTiming.actionReturned()
        let sentUnconfirmed = result.error == .cannotComplete && descriptor.hasMenu
        response["performed"] = [
            "status": result.error == .success ? "sent" : (sentUnconfirmed ? "sentUnconfirmed" : "failed"),
            "axErrorRawValue": result.error.rawValue,
            "milliseconds": result.milliseconds
        ]
        guard result.error == .success || sentUnconfirmed else {
            response["ok"] = false
            response["error"] = "performFailed"
            audit(request, dryRun: dryRun, kernel: described.decision, outcome: "performFailed", startedAt: startedAt)
            return response
        }

        let verifyStartedAt = Date()
        var evidence: String?
        var verifyPolls = 0
        while evidence == nil,
              Date().timeIntervalSince(verifyStartedAt) < Self.statusItemVerificationDeadlineInSeconds {
            verifyPolls += 1
            if let windowsBefore, let owner, AccessibilityMenu.windowCount(for: owner) != windowsBefore {
                evidence = "the owner's window count changed"
            } else if AccessibilityStatusItems.childCount(of: item.element) != childrenBefore {
                evidence = "the item's child count changed"
            } else if AccessibilityStatusItems.isSelected(item.element) != selectedBefore {
                evidence = "the item's AXSelected changed"
            } else if !ownerWasFrontmost,
                      AccessibilityTreeWalker.frontmost().application?.processIdentifier == ownerPid {
                evidence = "the owner became frontmost"
            } else {
                usleep(AccessibilityWindows.observationPollIntervalInMicroseconds)
            }
        }
        let verifyMilliseconds = Int(Date().timeIntervalSince(verifyStartedAt) * 1000)
        phaseTiming.verified(walks: verifyPolls, path: "poll")
        response["windowsAfter"] = (owner.flatMap(AccessibilityMenu.windowCount) ?? NSNull()) as Any

        if let evidence {
            response["verification"] = ["status": "confirmed", "evidence": evidence, "milliseconds": verifyMilliseconds]
            response["ok"] = true
            audit(request, dryRun: dryRun, kernel: described.decision, outcome: "confirmed", startedAt: startedAt)
        } else {
            response["verification"] = ["status": "notObserved", "milliseconds": verifyMilliseconds]
            response["ok"] = false
            response["error"] = "notVerified"
            audit(request, dryRun: dryRun, kernel: described.decision, outcome: "notObserved", startedAt: startedAt)
        }
        return response
    }

    // MARK: Audit

    private func audit(
        _ request: HarnessRequest,
        dryRun: Bool,
        kernel: String,
        outcome: String,
        startedAt: Date
    ) {
        audit(request, dryRun: dryRun, kernel: kernel, outcome: outcome, startedAt: startedAt,
              confirmedBy: currentConfirmedBy, phases: phaseTiming.wireFields)
    }

    private func audit(
        _ request: HarnessRequest,
        dryRun: Bool,
        kernel: String,
        outcome: String,
        startedAt: Date,
        confirmedBy: String?,
        phases: [String: Any]
    ) {
        let frontmost = AccessibilityTreeWalker.frontmost()
        appendAudit(HarnessPolicy.auditLine(
            at: startedAt,
            id: request.id,
            verb: request.verb.rawValue,
            target: Self.auditTarget(for: request),
            app: frontmost.application?.bundleIdentifier,
            session: Self.sessionIdentifier,
            dryRun: dryRun,
            confirmed: request.confirmed,
            kernel: kernel,
            outcome: outcome,
            milliseconds: elapsedMilliseconds(since: startedAt),
            frontmostSource: frontmost.source.rawValue,
            frontmostSystemWideError: frontmost.systemWideErrorRawValue,
            confirmedBy: confirmedBy,
            phases: phases
        ), at: startedAt)
    }

    private func pingResponse(_ request: HarnessRequest, dryRun: Bool, startedAt: Date) -> [String: Any] {
        audit(request, dryRun: dryRun, kernel: "n/a", outcome: "ok", startedAt: startedAt,
              confirmedBy: nil, phases: HarnessPhaseTiming().wireFields)
        let counters = stateLock.withLock { (failures: auditMirrorFailures, overflow: auditMirrorOverflowLines) }
        return [
            "ok": true,
            "harness": versionString,
            "dryRun": dryRun,
            "dryRunSource": globalDryRun ? "global --harness-dry-run" : (request.requestedDryRun == true ? "request" : "none"),
            "killSwitchPresent": Self.killSwitchIsPresent(),
            "socket": Self.socketURL.path,
            "auditMirrorFailures": counters.failures,
            "auditMirrorOverflowLines": counters.overflow
        ]
    }

    /// Append-only and rotated. The same line goes to the day-split mirror;
    /// mirror failures are counted, never fatal.
    private func appendAudit(_ line: String, at date: Date = Date()) {
        stateLock.lock(); defer { stateLock.unlock() }
        let data = Data((line + "\n").utf8)
        rotateAuditLogIfLarge()
        _ = Self.append(data, to: Self.auditLogURL)

        let mirrorURL = Self.auditMirrorURL(for: date)
        let mirrorBytes = ((try? FileManager.default.attributesOfItem(atPath: mirrorURL.path))?[.size] as? Int) ?? 0
        switch AuditMirrorCap.decision(
            currentBytes: mirrorBytes, lineBytes: data.count,
            markerWritten: auditMirrorFilesMarkedAsCapped.contains(mirrorURL.lastPathComponent)
        ) {
        case .append:
            if !Self.append(data, to: mirrorURL) { auditMirrorFailures += 1 }
        case .dropAndWriteMarker:
            auditMirrorFilesMarkedAsCapped.insert(mirrorURL.lastPathComponent)
            auditMirrorOverflowLines += 1
            let marker = "{\"timestamp\":\"\(HarnessPolicy.auditTimestampFormatter.string(from: date))\","
                + "\"session\":\"\(Self.sessionIdentifier)\",\"outcome\":\"auditMirrorCapReached\","
                + "\"message\":\"this mirror reached its \(AuditMirrorCap.dailyBytes)-byte daily cap; later lines today "
                + "are dropped here, still written to harness-audit.log, and counted by ping as auditMirrorOverflowLines\"}\n"
            if !Self.append(Data(marker.utf8), to: mirrorURL) { auditMirrorFailures += 1 }
        case .drop:
            auditMirrorOverflowLines += 1
        }
    }

    /// Owner-only (0600): audit lines name apps, targets and typed text.
    static func append(_ data: Data, to url: URL) -> Bool {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        return MeasurementLogFile.appendOwnerOnly(data, to: url)
    }

    /// Keep one rotated file.
    private func rotateAuditLogIfLarge() {
        let attributes = try? FileManager.default.attributesOfItem(atPath: Self.auditLogURL.path)
        guard let size = attributes?[.size] as? Int, size > Self.auditLogRotationBytes else { return }
        try? FileManager.default.removeItem(at: Self.rotatedAuditLogURL)
        try? FileManager.default.moveItem(at: Self.auditLogURL, to: Self.rotatedAuditLogURL)
    }

    private func elapsedMilliseconds(since date: Date) -> Int {
        Int(Date().timeIntervalSince(date) * 1000)
    }

    static func errorCode(for error: Error) -> String {
        guard let snapshotError = error as? AccessibilitySnapshotError else { return "snapshotFailed" }
        switch snapshotError {
        case .accessibilityPermissionNotGranted: return "accessibilityPermissionNotGranted"
        case .noFrontmostApplication: return "noFrontmostApplication"
        case .noFocusedWindow: return "noFocusedWindow"
        case .screenIsLocked: return "screenIsLocked"
        }
    }
}
