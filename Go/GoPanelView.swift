//
//  GoPanelView.swift
//  Go
//
//  The SwiftUI content hosted inside the menu bar panel: permissions, voice
//  status, the push-to-talk shortcut and quick settings.
//

import AVFoundation
import SwiftUI

struct GoPanelView: View {
    @ObservedObject var goController: GoController
    @ObservedObject var confirmations: HarnessConfirmations

    private var isReady: Bool { goController.hasCompletedOnboarding && goController.allPermissionsGranted }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Harness confirmations first: a pending question is the one thing
            // on this panel that something else is waiting on.
            ConfirmationPromptView(confirmations: confirmations)
            // Only here, not on the floating card: revoking is a panel chore.
            AlwaysRulesListView(confirmations: confirmations)

            VStack(alignment: .leading, spacing: 10) {
                panelHeader

                if isReady {
                    talkCard
                } else {
                    introCopy
                }

                if !goController.allPermissionsGranted {
                    permissionsCard
                }

                settingsCard

                if !goController.hasCompletedOnboarding && goController.allPermissionsGranted {
                    Button("Start") { goController.triggerOnboarding() }
                        .buttonStyle(GoPillButtonStyle(fullWidth: true))
                        .pointerCursor()
                }

                footerSection
            }
            .padding(GoPanelMetrics.inset)
        }
        .frame(width: 320)
        .background(panelBackground)
        .environment(\.colorScheme, .dark)
    }

    // MARK: - Header

    private var panelHeader: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(DS.Colors.accent.gradient)
                .frame(width: 30, height: 30)
                .overlay(
                    Image(systemName: "location.north.fill")
                        .font(.system(size: 13, weight: .bold))
                        .rotationEffect(.degrees(-35))
                        .foregroundStyle(DS.Colors.textOnAccent)
                )

            VStack(alignment: .leading, spacing: 1) {
                Text("Go")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(DS.Colors.textPrimary)
                HStack(spacing: 5) {
                    statusDot
                    Text(statusText)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(DS.Colors.textSecondary)
                }
            }

            Spacer()

            Button(action: {
                NotificationCenter.default.post(name: .goDismissPanel, object: nil)
            }) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(DS.Colors.textSecondary)
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(Color.white.opacity(0.1)))
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .accessibilityLabel("Close")
        }
        .padding(.horizontal, 2)
    }

    @ViewBuilder
    private var statusDot: some View {
        let dot = Circle()
            .fill(statusDotColor)
            .frame(width: 6, height: 6)
            .shadow(color: statusDotColor.opacity(0.7), radius: 3)
        if isBusy {
            // A slow breathe while Go listens or thinks.
            dot.phaseAnimator([1.0, 0.35]) { view, opacity in
                view.opacity(opacity)
            } animation: { _ in .easeInOut(duration: 0.8) }
        } else {
            dot
        }
    }

    // MARK: - Talk hint

    private var talkCard: some View {
        GoPanelCard {
            HStack(spacing: 6) {
                Text("Hold")
                GoKeyCap(symbol: "⌃", name: "control")
                GoKeyCap(symbol: "⌥", name: "option")
                Text("and talk")
                Spacer(minLength: 0)
            }
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(DS.Colors.textSecondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
        }
    }

    // MARK: - Intro copy

    @ViewBuilder
    private var introCopy: some View {
        if goController.allPermissionsGranted {
            Text("You're all set. Hit Start to meet Go.")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(DS.Colors.textSecondary)
                .padding(.horizontal, 2)
        } else if goController.hasCompletedOnboarding {
            // Permissions were revoked after onboarding — tell user to re-grant
            introText(
                title: "Permissions needed",
                body: "Some permissions were revoked. Grant all four below to keep using Go."
            )
        } else {
            introText(
                title: "Meet Go.",
                body: "Get step-by-step help with software on your Mac. Allow microphone, Accessibility, and screen access to use voice and screen assistance."
            )
        }
    }

    private func introText(title: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(DS.Colors.textPrimary)
            Text(body)
                .font(.system(size: 11))
                .foregroundStyle(DS.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 2)
    }

    // MARK: - Permissions

    private var permissionsCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel("Permissions")
            GoPanelCard {
                microphonePermissionRow
                GoPanelRowDivider()
                accessibilityPermissionRow
                GoPanelRowDivider()
                screenRecordingPermissionRow
                if goController.hasScreenRecordingPermission {
                    GoPanelRowDivider()
                    screenContentPermissionRow
                }
            }
        }
    }

    private func permissionRow<Grant: View>(
        icon: String,
        title: String,
        subtitle: String? = nil,
        isGranted: Bool,
        @ViewBuilder grant: () -> Grant
    ) -> some View {
        GoPanelRow(
            icon: icon,
            tint: isGranted ? DS.Colors.accent : DS.Colors.warning,
            title: title,
            subtitle: subtitle
        ) {
            if isGranted {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(DS.Colors.accent)
                    .accessibilityLabel("Granted")
            } else {
                grant()
            }
        }
    }

    private func grantButton(_ action: @escaping () -> Void) -> some View {
        Button("Grant", action: action)
            .buttonStyle(GoPillButtonStyle())
            .pointerCursor()
    }

    private var microphonePermissionRow: some View {
        permissionRow(icon: "mic.fill", title: "Microphone", isGranted: goController.hasMicrophonePermission) {
            grantButton {
                // Triggers the native macOS microphone permission dialog on
                // first attempt. If already denied, opens System Settings.
                let status = AVCaptureDevice.authorizationStatus(for: .audio)
                if status == .notDetermined {
                    AVCaptureDevice.requestAccess(for: .audio) { _ in }
                } else {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
    }

    private var accessibilityPermissionRow: some View {
        permissionRow(icon: "hand.raised.fill", title: "Accessibility", isGranted: goController.hasAccessibilityPermission) {
            HStack(spacing: 6) {
                Button("Find App") {
                    // Reveals the app in Finder so the user can drag it into
                    // the Accessibility list if it doesn't appear automatically
                    // (common with unsigned dev builds).
                    WindowPositionManager.revealAppInFinder()
                    WindowPositionManager.openAccessibilitySettings()
                }
                .buttonStyle(GoPillButtonStyle(prominent: false))
                .pointerCursor()

                grantButton {
                    // Triggers the system accessibility prompt (AXIsProcessTrustedWithOptions)
                    // on first attempt, then opens System Settings on subsequent attempts.
                    WindowPositionManager.requestAccessibilityPermission()
                }
            }
        }
    }

    private var screenRecordingPermissionRow: some View {
        let isGranted = goController.hasScreenRecordingPermission
        return permissionRow(
            icon: "rectangle.dashed.badge.record",
            title: "Screen Recording",
            subtitle: isGranted ? "Only takes a screenshot when you use the hotkey" : "Quit and reopen after granting",
            isGranted: isGranted
        ) {
            grantButton {
                // Triggers the native macOS screen recording prompt on first
                // attempt (auto-adds app to the list), then opens System Settings
                // on subsequent attempts.
                WindowPositionManager.requestScreenRecordingPermission()
            }
        }
    }

    private var screenContentPermissionRow: some View {
        permissionRow(icon: "eye.fill", title: "Screen Content", isGranted: goController.hasScreenContentPermission) {
            grantButton { goController.requestScreenContentPermission() }
        }
    }

    // MARK: - Settings

    private var settingsCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel("Settings")
            GoPanelCard {
                if isReady {
                    GoPanelSwitchRow(
                        icon: "cursorarrow.rays",
                        title: "Show Go cursor",
                        subtitle: "Off: it appears only while you talk.",
                        isOn: Binding(
                            get: { goController.isGoCursorEnabled },
                            set: { goController.setGoCursorEnabled($0) }
                        )
                    )
                    GoPanelRowDivider()
                }
                GoTrustedModeToggle()
                if isReady {
                    GoPanelRowDivider()
                    GoPanelRow(icon: "waveform", tint: Color(hex: "#E8793A"), title: "Voice") {
                        Text("Gemini + ElevenLabs")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(DS.Colors.textTertiary)
                    }
                }
            }
        }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(DS.Colors.textTertiary)
            .padding(.horizontal, 4)
    }

    // MARK: - Footer

    private var footerSection: some View {
        VStack(spacing: 0) {
            if goController.hasCompletedOnboarding {
                GoMenuRowButton(icon: "play.circle", title: "Show Welcome Again") {
                    goController.replayOnboarding()
                }
            }
            GoMenuRowButton(icon: "power", title: "Quit Go") {
                NSApp.terminate(nil)
            }
        }
    }

    // MARK: - Visual Helpers

    private var panelBackground: some View {
        let shape = RoundedRectangle(cornerRadius: GoPanelMetrics.cornerRadius, style: .continuous)
        return ZStack {
            GoGlassBackground()
            // A light tint so text stays readable over bright windows.
            DS.Colors.background.opacity(0.35)
        }
        .clipShape(shape)
        .overlay(shape.strokeBorder(Color.white.opacity(0.14), lineWidth: 0.5))
    }

    private var isBusy: Bool {
        goController.isOverlayVisible && goController.voiceState != .idle
    }

    private var statusDotColor: Color {
        if !goController.isOverlayVisible {
            return DS.Colors.textTertiary
        }
        switch goController.voiceState {
        case .idle, .listening:
            return DS.Colors.accent
        case .processing, .responding:
            return DS.Colors.blue400
        }
    }

    private var statusText: String {
        if !goController.hasCompletedOnboarding || !goController.allPermissionsGranted {
            return "Setup"
        }
        if !goController.isOverlayVisible {
            return "Ready"
        }
        switch goController.voiceState {
        case .idle:
            return "Active"
        case .listening:
            return "Listening"
        case .processing:
            return "Processing"
        case .responding:
            return "Responding"
        }
    }

}
