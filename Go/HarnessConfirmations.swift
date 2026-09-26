//
//  HarnessConfirmations.swift
//  Go
//
//  Confirmation tickets. When the kernel asks, the request returns a ticket
//  id at once, the card shows the question, the user answers, and the caller
//  re-issues with the id. A ticket matches exactly one action and is spent by
//  one execution. Main-thread only: SwiftUI observes `tickets`.
//

import AppKit
import Combine
import Foundation
import Security

final class HarnessConfirmations: ObservableObject {

    /// `stale`: the element or selection moved before the ticket was used. Terminal.
    nonisolated enum Status: String { case pending, allowed, denied, expired, stale }
    enum Scope: String { case once, always }

    /// Decides whether an approval press came from the user's real click.
    /// A real click is a fresh left mouse-up from the HID layer (source pid 0),
    /// in this window, inside the pressed button, on a row that hasn't just moved,
    /// and not already used for another answer. Scripted presses (AXPress, posted
    /// CGEvents) fail these checks. Deny counts from anything.
    nonisolated enum ApprovalInput {
        enum Verdict: Equatable {
            case accepted
            case rejected(reason: String)
        }

        static let approvalEventType: NSEvent.EventType = .leftMouseUp
        /// `clickCount` is only valid for these event types.
        static let mouseButtonEventTypes: Set<NSEvent.EventType> = [
            .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp
        ]

        /// Real clicks arrive within a few ms; older events are refused.
        static let maximumEventAgeSeconds: TimeInterval = 0.5
        /// A row must be still this long before its buttons count (longer than a
        /// double-click interval).
        static let minimumRowSettledSeconds: TimeInterval = 0.8

        /// What makes one `NSEvent` distinct from another.
        struct EventIdentity: Hashable {
            let typeRawValue: UInt
            let timestamp: TimeInterval
            let windowNumber: Int
            let mouseEventNumber: Int64
        }

        /// Everything the verdict looks at, gathered at the press. Pure data, so
        /// every rejection is testable.
        struct Evidence: Equatable {
            var eventType: NSEvent.EventType? = nil
            var sourceProcessID: Int64? = nil
            var clickCount: Int = 0
            var eventAgeSeconds: TimeInterval? = nil
            var eventWindowNumber: Int? = nil
            var hostWindowNumber: Int? = nil
            var rowSettledSeconds: TimeInterval? = nil
            var eventIdentity: EventIdentity? = nil
            /// AppKit, bottom-left origin. Mouse events only.
            var clickLocationInWindow: CGPoint? = nil
            /// Content height, to flip a bottom-left point to top-left.
            var hostContentHeight: CGFloat? = nil
            /// The pressed button's frame in SwiftUI `.global` space (top-left origin).
            var pressedButtonFrame: CGRect? = nil

            /// Reads a live event. Both clocks are seconds since boot.
            static func gathered(from event: NSEvent?, hostWindowNumber: Int?, rowSettledSeconds: TimeInterval?,
                                 hostContentHeight: CGFloat? = nil, pressedButtonFrame: CGRect? = nil,
                                 nowUptime: TimeInterval) -> Evidence {
                var evidence = Evidence(hostWindowNumber: hostWindowNumber, rowSettledSeconds: rowSettledSeconds,
                                        hostContentHeight: hostContentHeight, pressedButtonFrame: pressedButtonFrame)
                guard let event else { return evidence }
                let cgEvent = event.cgEvent
                evidence.eventType = event.type
                evidence.sourceProcessID = cgEvent?.getIntegerValueField(.eventSourceUnixProcessID)
                evidence.clickLocationInWindow = mouseButtonEventTypes.contains(event.type) ? event.locationInWindow : nil
                evidence.clickCount = mouseButtonEventTypes.contains(event.type) ? event.clickCount : 0
                evidence.eventAgeSeconds = nowUptime - event.timestamp
                evidence.eventWindowNumber = event.windowNumber
                evidence.eventIdentity = EventIdentity(
                    typeRawValue: event.type.rawValue, timestamp: event.timestamp, windowNumber: event.windowNumber,
                    mouseEventNumber: cgEvent?.getIntegerValueField(.mouseEventNumber) ?? 0
                )
                return evidence
            }
        }

        static func topLeftPoint(fromWindowPoint point: CGPoint, contentHeight: CGFloat) -> CGPoint {
            CGPoint(x: point.x, y: contentHeight - point.y)
        }

        /// Otherwise a scripted press could borrow a real click made anywhere in the card.
        static func clickLandsInsidePressedButton(_ evidence: Evidence) -> Bool {
            guard let location = evidence.clickLocationInWindow, let height = evidence.hostContentHeight,
                  let frame = evidence.pressedButtonFrame, !frame.isEmpty else { return false }
            return frame.contains(topLeftPoint(fromWindowPoint: location, contentHeight: height))
        }

        static func verdict(_ evidence: Evidence, eventAlreadyUsed: Bool) -> Verdict {
            guard let eventType = evidence.eventType else {
                return .rejected(reason: "no input event (programmatic press, e.g. Accessibility)")
            }
            guard eventType == approvalEventType else {
                return .rejected(reason: "event type \(eventType.rawValue) is not a left mouse-up — an approval counts only from a click released on the button")
            }
            guard let sourceProcessID = evidence.sourceProcessID else {
                return .rejected(reason: "event carries no source process")
            }
            guard sourceProcessID == 0 else {
                return .rejected(reason: "posted by process \(sourceProcessID)")
            }
            guard evidence.clickCount <= 1 else {
                return .rejected(reason: "click \(evidence.clickCount) of a multi-click — it may have landed on a row that moved under the first")
            }
            guard let age = evidence.eventAgeSeconds, age <= maximumEventAgeSeconds else {
                let shown = evidence.eventAgeSeconds.map { "\(Int($0 * 1000)) ms" } ?? "of unknown age"
                return .rejected(reason: "input event is \(shown) old, at most \(Int(maximumEventAgeSeconds * 1000)) ms — it is not the click that pressed this button")
            }
            guard let host = evidence.hostWindowNumber, evidence.eventWindowNumber == host else {
                return .rejected(reason: "input event belongs to window \(evidence.eventWindowNumber.map(String.init) ?? "none"), the button is in window \(evidence.hostWindowNumber.map(String.init) ?? "unknown")")
            }
            guard clickLandsInsidePressedButton(evidence) else {
                return .rejected(reason: "the click did not land inside the pressed button")
            }
            guard !eventAlreadyUsed else {
                return .rejected(reason: "this input event already reached an answer button")
            }
            guard let settled = evidence.rowSettledSeconds, settled >= minimumRowSettledSeconds else {
                let shown = evidence.rowSettledSeconds.map { "\(Int($0 * 1000)) ms" } ?? "an unknown time"
                return .rejected(reason: "the row had been in place \(shown), needs \(Int(minimumRowSettledSeconds * 1000)) ms — click again")
            }
            return .accepted
        }
    }

    nonisolated struct Ticket: Identifiable, Equatable {
        let id: String
        let createdAt: Date
        let verb: String
        /// Exactly what the request named: the match key, never shown.
        let rawTarget: String
        /// The escaped form the UI shows.
        let target: String
        /// `type` only: the text and mode are part of the action.
        let text: String?
        let mode: String?
        /// Resolution qualifiers are part of the match: "Delete in Drafts" is not
        /// "Delete in Bank".
        var withinNamed: String? = nil
        var nearPoint: CGPoint? = nil
        var role: String? = nil
        var thenConfirm: Bool = false
        let appName: String?
        let bundleIdentifier: String
        /// The kernel's reason, escaped (it can contain app-written text).
        let reason: String
        var status: Status
        var answeredAt: Date?
        /// One ticket, one action. Status stays `allowed` so the panel shows the answer.
        var consumed = false
        /// The lines the card shows, computed once, so what is shown and what is
        /// bound can't drift.
        var displayLines: [String] = []
        /// What the action would affect when the ticket opened; nil for focus/launch.
        var binding: ActionBinding? = nil
        var staleField: String? = nil
        /// The kernel's `destructive` flag, copied at open.
        var isDestructive = false

        var shape: Shape {
            Shape(verb: verb, bundleIdentifier: bundleIdentifier, rawTarget: rawTarget, text: text, mode: mode,
                  withinNamed: withinNamed, nearPoint: nearPoint, role: role, thenConfirm: thenConfirm)
        }

        var expiresAt: Date { createdAt.addingTimeInterval(HarnessConfirmations.ticketLifetimeInSeconds) }
    }

    /// The shape of one request, for matching tickets and rules.
    nonisolated struct Shape: Equatable {
        let verb: String
        let bundleIdentifier: String?
        let rawTarget: String
        var text: String? = nil
        var mode: String? = nil
        var withinNamed: String? = nil
        var nearPoint: CGPoint? = nil
        var role: String? = nil
        var thenConfirm: Bool = false
    }

    nonisolated enum Consumption: Equatable {
        case allowed, pending, denied, expired, unknown
        case consumed
        /// Names the field that differs.
        case mismatch(field: String)
        case stale(field: String)
    }

    enum OpenResult: Equatable {
        case opened(Ticket)
        case refused(code: String, message: String)
    }

    /// An "always" rule, stored in the Keychain. A nil target is app-wide for
    /// focus/launch and matches nothing otherwise; nil qualifiers mean "none",
    /// not "any".
    nonisolated struct ApprovalRule: Codable, Equatable {
        let bundleIdentifier: String
        let verb: String
        let target: String?
        var text: String? = nil
        var mode: String? = nil
        var withinNamed: String? = nil
        var nearPoint: CGPoint? = nil
        var role: String? = nil
        var thenConfirm: Bool? = nil
    }

    nonisolated static let ticketLifetimeInSeconds: TimeInterval = 60
    /// More open questions than this is a way to get a click on the wrong one.
    static let maximumPendingTickets = 3
    /// Verbs whose "always" rule covers the whole app.
    nonisolated static let appWideRuleVerbs: Set<String> = ["focus", "launch"]
    /// A question that can't be shown in full isn't asked.
    nonisolated static let maximumDisplayLineLength = 300

    /// Oldest first: appending never moves a row under the user's pointer.
    @Published private(set) var tickets: [Ticket] = []
    /// Input events that already reached an answer button; each is spent once.
    private var inputEventsThatReachedAnAnswerButton: [ApprovalInput.EventIdentity] = []
    private static let rememberedInputEventCount = 64
    /// Rules as last read, for the panel's list. The gate re-reads every time.
    @Published private(set) var alwaysRules: [ApprovalRule] = []
    /// Why the rules could not be read or saved, shown beside the list.
    @Published private(set) var alwaysRulesProblem: String?

    private let rulesStore: ApprovalRulesKeychainStore
    /// An old rules file location: reported if present, never read.
    private let ignoredApprovalsFileURL: URL?

    init(rulesStore: ApprovalRulesKeychainStore, ignoredApprovalsFileURL: URL? = nil) {
        self.rulesStore = rulesStore
        self.ignoredApprovalsFileURL = ignoredApprovalsFileURL
        refreshAlwaysRules()
    }

    // MARK: Pure

    nonisolated static func status(of ticket: Ticket, now: Date) -> Status {
        if ticket.status == .pending, now >= ticket.expiresAt { return .expired }
        return ticket.status
    }

    nonisolated static func ticketMatches(_ ticket: Ticket, _ shape: Shape) -> Bool {
        mismatchedField(ticket, shape) == nil
    }

    nonisolated static func mismatchedField(_ ticket: Ticket, _ shape: Shape) -> String? {
        mismatchedField(approved: ticket.shape, shape)
    }

    /// The one definition of "the same action", shared by tickets and rules.
    nonisolated static func mismatchedField(approved: Shape, _ shape: Shape) -> String? {
        if approved.verb != shape.verb { return "verb" }
        guard let approvedBundle = approved.bundleIdentifier,
              sameBundleIdentifier(approvedBundle, shape.bundleIdentifier) else { return "bundleIdentifier" }
        if approved.rawTarget != shape.rawTarget { return "target" }
        if approved.withinNamed != shape.withinNamed { return "withinNamed" }
        if approved.nearPoint != shape.nearPoint { return "nearPoint" }
        if approved.role != shape.role { return "role" }
        if approved.thenConfirm != shape.thenConfirm { return "thenConfirm" }
        if shape.verb == "type" {
            if approved.text != shape.text { return "text" }
            if approved.mode != shape.mode { return "mode" }
        }
        return nil
    }

    /// Every field of `shape` as a plain line. Escaped, never truncated; `open`
    /// refuses a line that is too long. A test checks every field has a line.
    static func displayLines(for shape: Shape, appName: String?, binding: ActionBinding?) -> [String] {
        displayLines(for: shape, appName: appName)
            + (binding.map { ActionBinding.displayLines(for: $0, bundleIdentifier: shape.bundleIdentifier) } ?? [])
    }

    static func displayLines(for shape: Shape, appName: String?) -> [String] {
        var lines = ["\(shape.verb) \(UntrustedText(shape.rawTarget).forDisplayInFull)"]
        if let withinNamed = shape.withinNamed { lines.append("within \(UntrustedText(withinNamed).forDisplayInFull)") }
        if let role = shape.role { lines.append("role \(UntrustedText(role).forDisplayInFull)") }
        if let point = shape.nearPoint { lines.append("at point (\(point.x), \(point.y))") }
        if shape.text != nil || shape.mode != nil {
            let text = shape.text.map { UntrustedText($0).forDisplayInFull } ?? "none"
            lines.append("text: \(text) (\(shape.mode ?? "no mode"))")
        }
        // `thenConfirm` also submits; the card must say so.
        if shape.thenConfirm { lines.append("then submits (AXConfirm)") }
        let app = appName.map { UntrustedText($0).forDisplayInFull } ?? "unnamed app"
        let bundle = shape.bundleIdentifier.map { UntrustedText($0).forDisplayInFull } ?? "no bundle identifier"
        lines.append("in \(app) (\(bundle))")
        return lines
    }

    /// A stored rule in the same words, for the panel's revoke list.
    static func displayLines(for rule: ApprovalRule) -> [String] {
        let shape = Shape(
            verb: rule.verb, bundleIdentifier: rule.bundleIdentifier, rawTarget: rule.target ?? "",
            text: rule.text, mode: rule.mode, withinNamed: rule.withinNamed, nearPoint: rule.nearPoint,
            role: rule.role, thenConfirm: rule.thenConfirm ?? false
        )
        let appName = NSWorkspace.shared.urlForApplication(withBundleIdentifier: rule.bundleIdentifier)
            .map { FileManager.default.displayName(atPath: $0.path) }
        var lines = displayLines(for: shape, appName: appName)
        if rule.target == nil { lines[0] = "\(rule.verb) (any target)" }
        return lines
    }

    static func consumption(of ticket: Ticket?, _ shape: Shape, now: Date) -> Consumption {
        guard let ticket else { return .unknown }
        if let field = mismatchedField(ticket, shape) { return .mismatch(field: field) }
        switch status(of: ticket, now: now) {
        case .pending: return .pending
        case .denied: return .denied
        case .expired: return .expired
        case .stale: return .stale(field: ticket.staleField ?? "binding")
        case .allowed: return ticket.consumed ? .consumed : .allowed
        }
    }

    static func displayedReason(_ reason: String) -> String {
        UntrustedText(reason).forDisplayInFull
    }

    /// Whether to offer "Always". Destructive questions get Allow once and Deny only.
    static func offersAlwaysRule(for ticket: Ticket) -> Bool {
        !ticket.isDestructive
    }

    static func alwaysButtonTitle(for ticket: Ticket) -> String {
        guard appWideRuleVerbs.contains(ticket.verb) else { return "Always allow exactly this" }
        return "Always allow \(ticket.verb) for the whole app \(ticket.appName ?? "(unnamed app)")"
    }

    /// Why a ticket may not be opened for this shape, or nil.
    static func openRefusal(for shape: Shape, appName: String? = nil, binding: ActionBinding? = nil, reason: String, pendingCount: Int) -> (code: String, message: String)? {
        if shape.rawTarget.isEmpty {
            return ("confirmationTargetUnnamed", "the request names no target, so a ticket for it would authorise anything")
        }
        if (shape.bundleIdentifier ?? "").isEmpty {
            return ("confirmationAppUnidentified", "the application has no bundle identifier, so a ticket could not be scoped to it")
        }
        // Count Unicode scalars: one Character can hold thousands of combining marks.
        let shownLines = displayLines(for: shape, appName: appName, binding: binding) + [displayedReason(reason)]
        if let longest = shownLines.map(\.unicodeScalars.count).max(), longest > maximumDisplayLineLength {
            return ("confirmationTooLongToShow",
                    "a line of the question is \(longest) unicode scalars and the panel shows at most \(maximumDisplayLineLength) in full — the owner cannot approve what they cannot read")
        }
        if pendingCount >= maximumPendingTickets {
            return ("tooManyPendingConfirmations",
                    "\(pendingCount) tickets are already waiting in the Go panel — answer or let them expire first")
        }
        return nil
    }

    /// Bundle id case-insensitive, everything else exact.
    nonisolated static func matchingRule(in rules: [ApprovalRule], _ shape: Shape) -> ApprovalRule? {
        rules.first { rule in
            if appWideRuleVerbs.contains(rule.verb), rule.target == nil {
                return rule.verb == shape.verb && sameBundleIdentifier(rule.bundleIdentifier, shape.bundleIdentifier)
            }
            guard let target = rule.target else { return false }
            let approved = Shape(
                verb: rule.verb, bundleIdentifier: rule.bundleIdentifier,
                rawTarget: target, text: rule.text, mode: rule.mode,
                withinNamed: rule.withinNamed, nearPoint: rule.nearPoint, role: rule.role,
                thenConfirm: rule.thenConfirm ?? false
            )
            return mismatchedField(approved: approved, shape) == nil
        }
    }

    /// The rule an "always" answer creates: exactly this action in this app
    /// (the whole app for focus/launch).
    nonisolated static func rule(for ticket: Ticket) -> ApprovalRule {
        if appWideRuleVerbs.contains(ticket.verb) {
            return ApprovalRule(bundleIdentifier: ticket.bundleIdentifier, verb: ticket.verb, target: nil)
        }
        return ApprovalRule(
            bundleIdentifier: ticket.bundleIdentifier, verb: ticket.verb, target: ticket.rawTarget,
            text: ticket.text, mode: ticket.mode, withinNamed: ticket.withinNamed, nearPoint: ticket.nearPoint,
            role: ticket.role, thenConfirm: ticket.thenConfirm ? true : nil
        )
    }

    nonisolated static func parseApprovals(_ data: Data) -> Result<[ApprovalRule], HarnessAppPolicy.ParseFailure> {
        do {
            return .success(try JSONDecoder().decode([ApprovalRule].self, from: data))
        } catch {
            return .failure(.init(reason: String(describing: error).prefix(200).description))
        }
    }

    nonisolated private static func sameBundleIdentifier(_ a: String, _ b: String?) -> Bool {
        guard let b else { return false }
        return a.caseInsensitiveCompare(b) == .orderedSame
    }

    // MARK: Mutating

    func pendingCount(now: Date = Date()) -> Int {
        tickets.filter { Self.status(of: $0, now: now) == .pending }.count
    }

    func ticket(id: String) -> Ticket? { tickets.first { $0.id == id } }

    func open(_ shape: Shape, appName: String?, reason: String, destructive: Bool, binding: ActionBinding? = nil) -> OpenResult {
        let now = Date()
        let pending = pendingCount(now: now)
        if let refusal = Self.openRefusal(for: shape, appName: appName, binding: binding, reason: reason, pendingCount: pending) {
            return .refused(code: refusal.code, message: refusal.message)
        }
        var ticket = Ticket(
            id: UUID().uuidString, createdAt: now, verb: shape.verb,
            rawTarget: shape.rawTarget, target: UntrustedText(shape.rawTarget).forDisplay,
            text: shape.text, mode: shape.mode,
            withinNamed: shape.withinNamed, nearPoint: shape.nearPoint, role: shape.role, thenConfirm: shape.thenConfirm,
            appName: appName.map { UntrustedText($0).forDisplay },
            bundleIdentifier: shape.bundleIdentifier ?? "", reason: Self.displayedReason(reason), status: .pending,
            displayLines: Self.displayLines(for: shape, appName: appName, binding: binding),
            binding: binding
        )
        ticket.isDestructive = destructive
        tickets.append(ticket)
        // Keep at most 20: evict the oldest answered ones, never a pending one.
        while tickets.count > 20,
              let index = tickets.firstIndex(where: { Self.status(of: $0, now: now) != .pending }) {
            tickets.remove(at: index)
        }
        // `ConfirmationCardWindowManager` shows the card on the next run-loop turn.
        return .opened(ticket)
    }

    /// The only entry point for a button pressed in Go's UI. Approvals need
    /// `ApprovalInput.verdict` to accept the evidence.
    @discardableResult
    func answerFromPanel(_ id: String, allow: Bool, scope: Scope, evidence: ApprovalInput.Evidence) -> ApprovalInput.Verdict {
        let eventAlreadyUsed = evidence.eventIdentity.map { inputEventsThatReachedAnAnswerButton.contains($0) } ?? false
        if let identity = evidence.eventIdentity, !eventAlreadyUsed {
            inputEventsThatReachedAnAnswerButton.append(identity)
            if inputEventsThatReachedAnAnswerButton.count > Self.rememberedInputEventCount {
                inputEventsThatReachedAnAnswerButton.removeFirst()
            }
        }
        let verdict: ApprovalInput.Verdict = allow ? ApprovalInput.verdict(evidence, eventAlreadyUsed: eventAlreadyUsed) : .accepted
        if verdict == .accepted { answer(id, allow: allow, scope: scope) }
        return verdict
    }

    /// Unchecked: for in-process callers that are not a button (tests).
    func answer(_ id: String, allow: Bool, scope: Scope) {
        guard let index = tickets.firstIndex(where: { $0.id == id }),
              Self.status(of: tickets[index], now: Date()) == .pending else { return }
        tickets[index].status = allow ? .allowed : .denied
        tickets[index].answeredAt = Date()
        // Hide the panel when nothing is left to ask, so focus returns to the app.
        if pendingCount() == 0 {
            DispatchQueue.main.async { NotificationCenter.default.post(name: .goDismissPanel, object: nil) }
        }
        guard allow, scope == .always, Self.offersAlwaysRule(for: tickets[index]) else { return }
        // Never overwrite a Keychain item we could not read.
        guard case .success(let rules) = rulesStore.load() else { refreshAlwaysRules(); return }
        let rule = Self.rule(for: tickets[index])
        guard !rules.contains(rule) else { return }
        let status = rulesStore.save(rules + [rule])
        refreshAlwaysRules()
        if status != errSecSuccess {
            alwaysRulesProblem = "\"Always\" was not saved (keychain OSStatus \(status)) — it allowed this once only"
        }
    }

    /// Removing a rule only narrows what runs, so it needs no proof of a click.
    func removeAlwaysRule(_ rule: ApprovalRule) {
        let status = rulesStore.remove(rule)
        refreshAlwaysRules()
        if status != errSecSuccess {
            alwaysRulesProblem = "rule not removed (keychain OSStatus \(status))"
        }
    }

    func refreshAlwaysRules() {
        switch rulesStore.load() {
        case .success(let rules):
            if alwaysRules != rules { alwaysRules = rules }
            if alwaysRulesProblem != nil { alwaysRulesProblem = nil }
        case .failure(let failure):
            if !alwaysRules.isEmpty { alwaysRules = [] }
            if alwaysRulesProblem != failure.reason { alwaysRulesProblem = failure.reason }
        }
    }

    /// `spend: false` reports the decision without using the ticket (dry runs).
    func consume(ticket id: String, _ shape: Shape, spend: Bool = true, now: Date = Date()) -> Consumption {
        let index = tickets.firstIndex { $0.id == id }
        let result = Self.consumption(of: index.map { tickets[$0] }, shape, now: now)
        if spend, result == .allowed, let index { tickets[index].consumed = true }
        return result
    }

    func invalidateAsStale(ticket id: String, movedPart: String, now: Date = Date()) {
        guard let index = tickets.firstIndex(where: { $0.id == id }) else { return }
        let status = Self.status(of: tickets[index], now: now)
        guard status == .pending || (status == .allowed && !tickets[index].consumed) else { return }
        tickets[index].status = .stale
        tickets[index].staleField = movedPart
        tickets[index].answeredAt = now
    }

    /// Consults the Keychain every time, so a removed rule stops applying at once.
    /// Destructive questions never match a rule.
    nonisolated func rule(for shape: Shape, destructive: Bool) -> (rule: ApprovalRule?, unreadable: String?, ignoredFile: String?) {
        // Reports a dangling symlink too.
        let ignoredFile = ignoredApprovalsFileURL.flatMap {
            (try? FileManager.default.attributesOfItem(atPath: $0.path)) != nil ? $0.path : nil
        }
        switch rulesStore.load() {
        case .success(let rules): return (destructive ? nil : Self.matchingRule(in: rules, shape), nil, ignoredFile)
        case .failure(let failure): return (nil, failure.reason, ignoredFile)
        }
    }
}
