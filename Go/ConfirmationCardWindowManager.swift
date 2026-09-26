//
//  ConfirmationCardWindowManager.swift
//  Go
//
//  Shows pending confirmation tickets as a small floating card at the top
//  right of the screen with the pointer, even over full-screen apps. The card
//  never takes focus or switches Spaces.
//

import AppKit
import Combine
import SwiftUI

private final class ConfirmationCardPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Accept the first click, so a non-key window doesn't need two.
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
final class ConfirmationCardWindowManager {
    private let confirmations: HarnessConfirmations
    private var panel: ConfirmationCardPanel?
    private var ticketsSubscription: AnyCancellable?

    private let cardWidth: CGFloat = 320
    private let screenEdgeMargin: CGFloat = 12

    init(confirmations: HarnessConfirmations) {
        self.confirmations = confirmations
        // Delivered on the next run-loop turn, never inside the request that opened
        // the ticket.
        ticketsSubscription = confirmations.$tickets
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refresh() }
    }

    private func refresh() {
        let now = Date()
        let pending = confirmations.tickets.filter { HarnessConfirmations.status(of: $0, now: now) == .pending }
        guard let soonestExpiry = pending.map(\.expiresAt).min() else {
            panel?.orderOut(nil)
            return
        }
        // Expiry publishes nothing, so check again when the soonest ticket lapses.
        DispatchQueue.main.asyncAfter(deadline: .now() + soonestExpiry.timeIntervalSince(now) + 0.1) { [weak self] in
            self?.refresh()
        }

        let panel = panel ?? makePanel()
        self.panel = panel
        positionAtTopRightOfPointerScreen(panel)
        panel.orderFrontRegardless()
    }

    private func makePanel() -> ConfirmationCardPanel {
        let card = ConfirmationPromptView(confirmations: confirmations, includesAnsweredTickets: false)
            .padding(.bottom, 12)
            .frame(width: cardWidth)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(DS.Colors.background)
            )
        let hostingView = FirstMouseHostingView(rootView: card)
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = .clear

        let cardPanel = ConfirmationCardPanel(
            contentRect: NSRect(x: 0, y: 0, width: cardWidth, height: 160),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        cardPanel.isFloatingPanel = true
        // Above the menu bar and full-screen windows, below pop-up menus and Go's cursor.
        cardPanel.level = .statusBar
        cardPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        cardPanel.hidesOnDeactivate = false
        cardPanel.isExcludedFromWindowsMenu = true
        cardPanel.isOpaque = false
        cardPanel.backgroundColor = .clear
        cardPanel.hasShadow = true
        cardPanel.contentView = hostingView
        return cardPanel
    }

    private func positionAtTopRightOfPointerScreen(_ panel: NSPanel) {
        let pointer = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(pointer, $0.frame, false) }) ?? NSScreen.main else { return }
        let height = panel.contentView?.fittingSize.height ?? 160
        // `frame`, not `visibleFrame`: a full-screen Space hides the menu bar.
        let top = screen.frame.maxY - NSStatusBar.system.thickness - screenEdgeMargin
        let right = screen.visibleFrame.maxX - screenEdgeMargin
        panel.setFrame(NSRect(x: right - cardWidth, y: top - height, width: cardWidth, height: height), display: true)
    }
}
