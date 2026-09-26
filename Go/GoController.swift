//
//  GoController.swift
//  Go
//
//  Go's app-wide state: permissions, onboarding, the push-to-talk shortcut,
//  the cursor overlay and the voice session. The panel and the overlay
//  observe it.
//

import AVFoundation
import Combine
import Foundation
import ScreenCaptureKit
import SwiftUI

enum GoVoiceState {
    case idle
    case listening
    case processing
    case responding
}

@MainActor
final class GoController: ObservableObject {
    @Published private(set) var voiceState: GoVoiceState = .idle

    @Published private(set) var currentAudioPowerLevel: CGFloat = 0
    @Published private(set) var hasAccessibilityPermission = false
    @Published private(set) var hasScreenRecordingPermission = false
    @Published private(set) var hasMicrophonePermission = false
    @Published private(set) var hasScreenContentPermission = false

    /// Where the cursor should fly and point (global AppKit coordinates).
    @Published var detectedElementScreenLocation: CGPoint?
    /// The frame of the screen that target is on.
    @Published var detectedElementDisplayFrame: CGRect?
    /// Bubble text for the pointing animation.
    @Published var detectedElementBubbleText: String?
    /// Go is acting on its own (do it for me, routine replay). The pointer then
    /// stays where it last acted between steps instead of returning to the mouse.
    @Published private(set) var isGoDriving = false
    /// The target the pointer last landed on, set by the overlay.
    var pointerLandedAt: CGPoint?
    /// The current walkthrough instruction, beside the cursor while it follows
    /// the mouse.
    @Published var guideBubbleText: String?

    // MARK: - Onboarding prompt

    @Published var onboardingPromptText: String = ""
    @Published var onboardingPromptOpacity: Double = 0.0
    @Published var showOnboardingPrompt: Bool = false

    let globalPushToTalkShortcutMonitor = GlobalPushToTalkShortcutMonitor()
    let overlayWindowManager = OverlayWindowManager()

    /// The Cloudflare worker's base URL (see `WorkerConfiguration`).
    static var workerBaseURL: String { WorkerConfiguration.baseURL }

    private(set) lazy var elevenLabsTTSClient: ElevenLabsTTSClient = {
        return ElevenLabsTTSClient(proxyURL: "\(Self.workerBaseURL)/tts")
    }()

    private var shortcutTransitionCancellable: AnyCancellable?

    private var accessibilityCheckTimer: Timer?

    /// A scheduled hide in transient mode, cancelled if the user speaks again.
    private var transientHideTask: Task<Void, Never>?

    /// Accessibility, Screen Recording and Microphone are all granted.
    var allPermissionsGranted: Bool {
        hasAccessibilityPermission && hasScreenRecordingPermission && hasMicrophonePermission && hasScreenContentPermission
    }

    @Published private(set) var isOverlayVisible: Bool = false

    /// Set by the app delegate before `start()`; push-to-talk goes here.
    var realtimeVoiceSession: RealtimeVoiceSession?
    private var guideHighlightIsVisible = false

    /// Whether the cursor is shown. Off hides the overlay and disables push-to-talk.
    @Published var isGoCursorEnabled: Bool = UserDefaults.standard.object(forKey: "isGoCursorEnabled") == nil
        ? true
        : UserDefaults.standard.bool(forKey: "isGoCursorEnabled")

    var hasCompletedOnboarding: Bool {
        get { UserDefaults.standard.bool(forKey: "hasCompletedOnboarding") }
        set { UserDefaults.standard.set(newValue, forKey: "hasCompletedOnboarding") }
    }

    func start() {
        refreshAllPermissions()
        print("🔑 Go start — accessibility: \(hasAccessibilityPermission), screen: \(hasScreenRecordingPermission), mic: \(hasMicrophonePermission), screenContent: \(hasScreenContentPermission), onboarded: \(hasCompletedOnboarding)")
        startPermissionPolling()

        bindShortcutTransitions()
        realtimeVoiceSession?.onStateChange = { [weak self] state in
            guard let self else { return }
            self.voiceState = state
            if state == .idle { self.scheduleTransientHideIfNeeded() }
        }
        realtimeVoiceSession?.onGuideText = { [weak self] text in
            self?.guideBubbleText = text
        }
        realtimeVoiceSession?.onGuideHighlight = { [weak self] rect in
            guard let self else { return }
            if self.guideHighlightIsVisible { ElementHighlightOverlay.hide(); self.guideHighlightIsVisible = false }
            guard let rect, let screen = NSScreen.screens.first(where: { $0.frame.intersects(rect) }),
                  let index = NSScreen.screens.firstIndex(of: screen) else { return }
            ElementHighlightOverlay.show(rect.insetBy(dx: -5, dy: -3), label: nil, onScreenAt: index, seconds: 600)
            self.guideHighlightIsVisible = true
        }
        realtimeVoiceSession?.onGuidePoint = { [weak self] rect, text in
            guard let self else { return }
            if self.guideHighlightIsVisible { ElementHighlightOverlay.hide(); self.guideHighlightIsVisible = false }
            self.detectedElementScreenLocation = nil
            self.detectedElementBubbleText = rect == nil ? nil : text
            self.detectedElementDisplayFrame = nil
            guard let rect, let screen = NSScreen.screens.first(where: { $0.frame.intersects(rect) }) else { return }
            self.voiceState = .idle
            self.detectedElementDisplayFrame = screen.frame
            self.detectedElementScreenLocation = CGPoint(x: rect.midX, y: rect.midY)
            if let index = NSScreen.screens.firstIndex(of: screen) {
                // Stays until the step changes.
                ElementHighlightOverlay.show(rect.insetBy(dx: -5, dy: -3), label: nil, onScreenAt: index, seconds: 600)
                self.guideHighlightIsVisible = true
            }
        }
        realtimeVoiceSession?.onAutopilotChanged = { [weak self] driving in
            self?.isGoDriving = driving
        }
        realtimeVoiceSession?.onAwaitPointer = { [weak self] in
            await self?.waitForPointerToLand()
        }
        realtimeVoiceSession?.prewarm()

        // Show the cursor at once if onboarding is done and permissions still hold.
        if hasCompletedOnboarding && allPermissionsGranted && isGoCursorEnabled {
            overlayWindowManager.hasShownOverlayBefore = true
            overlayWindowManager.showOverlay(onScreens: NSScreen.screens, goController: self)
            isOverlayVisible = true
        }
    }

    /// First run: dismiss the panel, show the cursor, play the welcome, then show
    /// the push-to-talk prompt.
    func triggerOnboarding() {
        NotificationCenter.default.post(name: .goDismissPanel, object: nil)
        hasCompletedOnboarding = true

        // A first appearance plays the welcome animation.
        overlayWindowManager.hasShownOverlayBefore = false
        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, goController: self)
        isOverlayVisible = true
    }

    func replayOnboarding() {
        NotificationCenter.default.post(name: .goDismissPanel, object: nil)

        overlayWindowManager.hasShownOverlayBefore = false
        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, goController: self)
        isOverlayVisible = true
    }

    /// Waits until the pointer has landed on the current target, so an action
    /// never happens before the owner can see where. Returns early when the
    /// cursor is hidden or the step has nothing to point at (a keyboard step).
    func waitForPointerToLand() async {
        let clock = ContinuousClock()
        let started = clock.now
        while isOverlayVisible, clock.now - started < .milliseconds(1800), !Task.isCancelled {
            if let target = detectedElementScreenLocation {
                if pointerLandedAt == target {
                    // A short beat on the target before acting.
                    try? await Task.sleep(for: .milliseconds(150))
                    return
                }
            } else if clock.now - started > .milliseconds(700) {
                return
            }
            try? await Task.sleep(for: .milliseconds(30))
        }
    }

    /// The panel's "Show Go cursor" switch. Off lets the cursor finish what it is
    /// saying or pointing at, then fade; push-to-talk still brings it back.
    func setGoCursorEnabled(_ enabled: Bool) {
        isGoCursorEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "isGoCursorEnabled")
        if enabled {
            transientHideTask?.cancel()
            transientHideTask = nil
            guard hasCompletedOnboarding && allPermissionsGranted && !isOverlayVisible else { return }
            overlayWindowManager.hasShownOverlayBefore = true
            overlayWindowManager.showOverlay(onScreens: NSScreen.screens, goController: self)
            isOverlayVisible = true
        } else {
            scheduleTransientHideIfNeeded()
        }
    }

    func clearDetectedElementLocation() {
        detectedElementScreenLocation = nil
        detectedElementDisplayFrame = nil
        detectedElementBubbleText = nil
    }

    func stop() {
        globalPushToTalkShortcutMonitor.stop()
        realtimeVoiceSession?.stop()

        overlayWindowManager.hideOverlay()
        transientHideTask?.cancel()

        shortcutTransitionCancellable?.cancel()

        accessibilityCheckTimer?.invalidate()
        accessibilityCheckTimer = nil
    }

    func refreshAllPermissions() {
        let previouslyHadAccessibility = hasAccessibilityPermission
        let previouslyHadScreenRecording = hasScreenRecordingPermission
        let previouslyHadMicrophone = hasMicrophonePermission
        let previouslyHadAll = allPermissionsGranted

        let currentlyHasAccessibility = WindowPositionManager.hasAccessibilityPermission()
        hasAccessibilityPermission = currentlyHasAccessibility

        if currentlyHasAccessibility {
            globalPushToTalkShortcutMonitor.start()
        } else {
            globalPushToTalkShortcutMonitor.stop()
        }

        hasScreenRecordingPermission = WindowPositionManager.hasScreenRecordingPermission()

        let micAuthStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        hasMicrophonePermission = micAuthStatus == .authorized

        if previouslyHadAccessibility != hasAccessibilityPermission
            || previouslyHadScreenRecording != hasScreenRecordingPermission
            || previouslyHadMicrophone != hasMicrophonePermission {
            print("🔑 Permissions — accessibility: \(hasAccessibilityPermission), screen: \(hasScreenRecordingPermission), mic: \(hasMicrophonePermission), screenContent: \(hasScreenContentPermission)")
        }

        if !previouslyHadAccessibility && hasAccessibilityPermission {
        }
        if !previouslyHadScreenRecording && hasScreenRecordingPermission {
        }
        if !previouslyHadMicrophone && hasMicrophonePermission {
        }
        // Once approved, the screen content picker isn't needed again.
        if !hasScreenContentPermission {
            hasScreenContentPermission = UserDefaults.standard.bool(forKey: "hasScreenContentPermission")
        }

        if !previouslyHadAll && allPermissionsGranted {
        }
    }

    /// Triggers the screen content picker with a throwaway capture, and remembers
    /// the grant.
    @Published private(set) var isRequestingScreenContent = false

    func requestScreenContentPermission() {
        guard !isRequestingScreenContent else { return }
        isRequestingScreenContent = true
        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let display = content.displays.first else {
                    await MainActor.run { isRequestingScreenContent = false }
                    return
                }
                let filter = SCContentFilter(display: display, excludingWindows: [])
                let config = SCStreamConfiguration()
                config.width = 320
                config.height = 240
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                // An empty image means the user denied it.
                let didCapture = image.width > 0 && image.height > 0
                print("🔑 Screen content capture result — width: \(image.width), height: \(image.height), didCapture: \(didCapture)")
                await MainActor.run {
                    isRequestingScreenContent = false
                    guard didCapture else { return }
                    hasScreenContentPermission = true
                    UserDefaults.standard.set(true, forKey: "hasScreenContentPermission")

                    if hasCompletedOnboarding && allPermissionsGranted && !isOverlayVisible && isGoCursorEnabled {
                        overlayWindowManager.hasShownOverlayBefore = true
                        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, goController: self)
                        isOverlayVisible = true
                    }
                }
            } catch {
                print("⚠️ Screen content permission request failed: \(error)")
                await MainActor.run { isRequestingScreenContent = false }
            }
        }
    }

    // MARK: - Private

    /// Polls permissions so the panel updates as they are granted (Screen
    /// Recording needs a relaunch to take effect).
    private func startPermissionPolling() {
        accessibilityCheckTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshAllPermissions()
            }
        }
    }

    private func bindShortcutTransitions() {
        shortcutTransitionCancellable = globalPushToTalkShortcutMonitor
            .shortcutTransitionPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] transition in
                self?.handleShortcutTransition(transition)
            }
    }

    private func handleShortcutTransition(_ transition: PushToTalkShortcut.ShortcutTransition) {
        guard let realtimeVoiceSession else { return }
        handleRealtimeShortcutTransition(transition, session: realtimeVoiceSession)
    }

    /// Overlay housekeeping, then the session does the rest.
    private func handleRealtimeShortcutTransition(_ transition: PushToTalkShortcut.ShortcutTransition, session: RealtimeVoiceSession) {
        switch transition {
        case .pressed:
            transientHideTask?.cancel()
            transientHideTask = nil
            if !isGoCursorEnabled && !isOverlayVisible {
                overlayWindowManager.hasShownOverlayBefore = true
                overlayWindowManager.showOverlay(onScreens: NSScreen.screens, goController: self)
                isOverlayVisible = true
            }
            NotificationCenter.default.post(name: .goDismissPanel, object: nil)
            session.pressed()
        case .released:
            session.released()
        case .none:
            break
        }
    }

    // MARK: - Transient cursor

    /// With "Show Go" off, hide the cursor a second after speech and pointing finish.
    private func scheduleTransientHideIfNeeded() {
        guard !isGoCursorEnabled && isOverlayVisible else { return }

        transientHideTask?.cancel()
        transientHideTask = Task {
            while elevenLabsTTSClient.isPlaying {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
            }

            while detectedElementScreenLocation != nil {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
            }

            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            overlayWindowManager.fadeOutAndHideOverlay()
            isOverlayVisible = false
        }
    }

    // MARK: - Onboarding prompt

    /// Shows the short first-run instruction beside the cursor, after the welcome.
    func startOnboardingPrompt() {
        let message = "hold \(PushToTalkShortcut.currentShortcutOption.holdPhrase) to talk"
        onboardingPromptText = ""
        showOnboardingPrompt = true
        onboardingPromptOpacity = 0.0

        withAnimation(.easeIn(duration: 0.4)) {
            onboardingPromptOpacity = 1.0
        }

        var currentIndex = 0
        Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { timer in
            guard currentIndex < message.count else {
                timer.invalidate()
                DispatchQueue.main.asyncAfter(deadline: .now() + 10.0) {
                    guard self.showOnboardingPrompt else { return }
                    withAnimation(.easeOut(duration: 0.3)) {
                        self.onboardingPromptOpacity = 0.0
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        self.showOnboardingPrompt = false
                        self.onboardingPromptText = ""
                    }
                }
                return
            }

            let index = message.index(message.startIndex, offsetBy: currentIndex)
            MainActor.assumeIsolated { self.onboardingPromptText.append(message[index]) }
            currentIndex += 1
        }
    }
}
