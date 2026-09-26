//
//  ConfirmationPromptView.swift
//  Go
//
//  The confirmation question and its buttons, shown in the card and the panel.
//  Every string shown is ours or already escaped by `HarnessConfirmations`.
//

import AppKit
import SwiftUI

struct ConfirmationPromptView: View {
    @ObservedObject var confirmations: HarnessConfirmations
    /// The panel keeps answered rows for a while; the card shows only open ones.
    var includesAnsweredTickets = true
    /// Why the last approval press on a ticket didn't count (our words only).
    @State private var approvalRejections: [String: String] = [:]
    /// Where rows and the window sit, for the "row must be still" check.
    @State private var placementTracker = ConfirmationPlacementTracker()

    static let lingerInSeconds: TimeInterval = 20

    static func visibleTickets(_ tickets: [HarnessConfirmations.Ticket], now: Date, includesAnswered: Bool = true) -> [HarnessConfirmations.Ticket] {
        tickets.filter { ticket in
            switch HarnessConfirmations.status(of: ticket, now: now) {
            case .pending: return true
            case .expired: return includesAnswered && now.timeIntervalSince(ticket.expiresAt) < lingerInSeconds
            case .allowed, .denied, .stale: return includesAnswered && now.timeIntervalSince(ticket.answeredAt ?? now) < lingerInSeconds
            }
        }
    }

    static func buttonFrameKey(_ ticketID: String, _ button: String) -> String { "\(ticketID)|\(button)" }

    /// Records a button's frame, so a click counts only inside the pressed button.
    private func recordsFrame(of button: String, ticketID: String) -> some View {
        GeometryReader { proxy in
            Color.clear.onChange(of: proxy.frame(in: .global), initial: true) { _, frame in
                placementTracker.buttonFrames[Self.buttonFrameKey(ticketID, button)] = frame
            }
        }
    }

    /// Every button goes through here, so the input check can't be skipped.
    private func press(_ button: String, _ ticket: HarnessConfirmations.Ticket, allow: Bool, scope: HarnessConfirmations.Scope) {
        let event = NSApp.currentEvent
        let nowUptime = ProcessInfo.processInfo.systemUptime
        // Re-read the window too, in case a move notification never came.
        placementTracker.windowChanged()
        let evidence = HarnessConfirmations.ApprovalInput.Evidence.gathered(
            from: event,
            hostWindowNumber: placementTracker.hostWindow?.windowNumber,
            rowSettledSeconds: ScreenPlacement.settledSeconds(
                row: placementTracker.rowPlacements[ticket.id], window: placementTracker.windowPlacement, nowUptime: nowUptime
            ),
            // Both panels host SwiftUI as the content view, so these share one space.
            hostContentHeight: placementTracker.hostWindow?.contentView?.bounds.height,
            pressedButtonFrame: placementTracker.buttonFrames[Self.buttonFrameKey(ticket.id, button)],
            nowUptime: nowUptime
        )
        let verdict = confirmations.answerFromPanel(ticket.id, allow: allow, scope: scope, evidence: evidence)
        if case .rejected(let reason) = verdict { approvalRejections[ticket.id] = reason } else { approvalRejections[ticket.id] = nil }
    }

    var body: some View {
        if confirmations.tickets.isEmpty {
            EmptyView()
        } else {
            // A one-second clock so tickets grey out when they expire.
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let visible = Self.visibleTickets(confirmations.tickets, now: context.date, includesAnswered: includesAnsweredTickets)
                if !visible.isEmpty {
                    VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                        ForEach(visible) { ticket in
                            row(ticket, now: context.date)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .background(HostWindowReader(tracker: placementTracker))
                }
            }
        }
    }

    @ViewBuilder
    private func row(_ ticket: HarnessConfirmations.Ticket, now: Date) -> some View {
        let status = HarnessConfirmations.status(of: ticket, now: now)
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            Text("Go asks to:")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(status == .pending ? DS.Colors.textPrimary : DS.Colors.textTertiary)
            // Exactly the lines the ticket binds, never truncated.
            ForEach(Array(ticket.displayLines.enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(DS.Colors.codeText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(ticket.reason)
                .font(.system(size: 11))
                .foregroundStyle(DS.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if status == .pending {
                HStack(spacing: DS.Spacing.sm) {
                    Button("Allow once") { press("allowOnce", ticket, allow: true, scope: .once) }
                        .background(recordsFrame(of: "allowOnce", ticketID: ticket.id))
                    if HarnessConfirmations.offersAlwaysRule(for: ticket) {
                        Button(HarnessConfirmations.alwaysButtonTitle(for: ticket)) { press("always", ticket, allow: true, scope: .always) }
                            .background(recordsFrame(of: "always", ticketID: ticket.id))
                    }
                    Button("Deny") { press("deny", ticket, allow: false, scope: .once) }
                        .tint(DS.Colors.destructive)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                if let rejection = approvalRejections[ticket.id] {
                    Text(verbatim: "Not counted: \(rejection)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(DS.Colors.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text(status == .stale ? "stale — ask again (the \(ticket.staleField ?? "binding") changed)" : status.rawValue)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(status == .allowed ? DS.Colors.success
                                     : status == .denied ? DS.Colors.destructiveText : DS.Colors.textTertiary)
            }
        }
        .padding(DS.Spacing.md)
        .background(DS.Colors.surface2)
        .clipShape(RoundedRectangle(cornerRadius: DS.CornerRadius.medium))
        .overlay(RoundedRectangle(cornerRadius: DS.CornerRadius.medium)
            .stroke(status == .pending ? DS.Colors.warning : DS.Colors.borderSubtle, lineWidth: 1))
        // Any move of the row restarts its clock, so a click can't land on a ticket
        // that slid under the pointer.
        .background(GeometryReader { proxy in
            Color.clear.onChange(of: proxy.frame(in: .global).origin, initial: true) { _, origin in
                placementTracker.rowPlacements[ticket.id] = ScreenPlacement.after(
                    placementTracker.rowPlacements[ticket.id], origin: origin, nowUptime: ProcessInfo.processInfo.systemUptime
                )
            }
        })
    }
}

/// Where something sits, and since when (seconds since boot).
nonisolated struct ScreenPlacement: Equatable {
    let origin: CGPoint
    let sinceUptime: TimeInterval

    static func after(_ previous: ScreenPlacement?, origin: CGPoint, nowUptime: TimeInterval) -> ScreenPlacement {
        if let previous, previous.origin == origin { return previous }
        return ScreenPlacement(origin: origin, sinceUptime: nowUptime)
    }

    /// How long a row has been still in a still, visible window; nil if unknown.
    static func settledSeconds(row: ScreenPlacement?, window: ScreenPlacement?, nowUptime: TimeInterval) -> TimeInterval? {
        guard let row, let window else { return nil }
        return nowUptime - max(row.sinceUptime, window.sinceUptime)
    }
}

/// Tracks the hosting window's position too: moving the whole window leaves
/// row origins unchanged.
final class ConfirmationPlacementTracker {
    private(set) weak var hostWindow: NSWindow?
    /// nil while the window is hidden.
    private(set) var windowPlacement: ScreenPlacement?
    var rowPlacements: [String: ScreenPlacement] = [:]
    var buttonFrames: [String: CGRect] = [:]
    private var windowObservers: [NSObjectProtocol] = []

    func attach(to window: NSWindow?) {
        guard window !== hostWindow else { return }
        for observer in windowObservers { NotificationCenter.default.removeObserver(observer) }
        windowObservers = []
        hostWindow = window
        windowPlacement = nil
        guard let window else { return }
        let names = [NSWindow.didMoveNotification, NSWindow.didResizeNotification, NSWindow.didChangeOcclusionStateNotification]
        for name in names {
            // Delivered synchronously on main, so the clock resets before the next click.
            windowObservers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: nil) { [weak self] _ in
                MainActor.assumeIsolated { self?.windowChanged() }
            })
        }
        windowChanged()
    }

    func windowChanged() {
        guard let window = hostWindow, window.occlusionState.contains(.visible) else {
            windowPlacement = nil
            return
        }
        // Top-left, so a taller card keeps its rows' clocks.
        windowPlacement = ScreenPlacement.after(
            windowPlacement, origin: CGPoint(x: window.frame.minX, y: window.frame.maxY),
            nowUptime: ProcessInfo.processInfo.systemUptime
        )
    }
}

private struct HostWindowReader: NSViewRepresentable {
    let tracker: ConfirmationPlacementTracker
    func makeNSView(context: Context) -> WindowReportingView {
        let view = WindowReportingView()
        view.tracker = tracker
        return view
    }
    func updateNSView(_ nsView: WindowReportingView, context: Context) {}
}

private final class WindowReportingView: NSView {
    weak var tracker: ConfirmationPlacementTracker?
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        tracker?.attach(to: window)
    }
    /// Never takes a click meant for the rows.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// The "Always" rules, with Remove. Removing only narrows, so it needs no
/// hardware-click check.
struct AlwaysRulesListView: View {
    @ObservedObject var confirmations: HarnessConfirmations

    var body: some View {
        Group {
            if !confirmations.alwaysRules.isEmpty || confirmations.alwaysRulesProblem != nil {
                VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                    Text("Always rules")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(DS.Colors.textPrimary)
                    if let problem = confirmations.alwaysRulesProblem {
                        Text(problem)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(DS.Colors.warning)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(Array(confirmations.alwaysRules.enumerated()), id: \.offset) { _, rule in
                        HStack(alignment: .top, spacing: DS.Spacing.sm) {
                            VStack(alignment: .leading, spacing: 0) {
                                ForEach(Array(HarnessConfirmations.displayLines(for: rule).enumerated()), id: \.offset) { _, line in
                                    Text(line)
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(DS.Colors.codeText)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            Spacer(minLength: 0)
                            Button("Remove") { confirmations.removeAlwaysRule(rule) }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                        }
                    }
                }
                .padding(DS.Spacing.md)
                .background(DS.Colors.surface2)
                .clipShape(RoundedRectangle(cornerRadius: DS.CornerRadius.medium))
                .padding(.horizontal, 16)
                .padding(.top, 12)
            }
        }
        // Re-read the rules whenever the panel is shown.
        .onAppear { confirmations.refreshAlwaysRules() }
    }
}
