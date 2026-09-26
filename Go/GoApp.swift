//
//  GoApp.swift
//  Go
//
//  App entry point. Go lives in the menu bar: no Dock icon and no main window.
//

import AppKit
import ServiceManagement
import SwiftUI

@main
struct GoApp: App {
    @NSApplicationDelegateAdaptor(GoAppDelegate.self) var appDelegate

    var body: some Scene {
        // Required by SwiftUI but never shown.
        Settings {
            EmptyView()
        }
    }
}

/// Creates the menu bar panel, the harness and the voice session at launch.
@MainActor
final class GoAppDelegate: NSObject, NSApplicationDelegate {
    private var menuBarPanelManager: MenuBarPanelManager?
    /// Shows pending confirmations on whatever Space the user is on.
    private var confirmationCardWindowManager: ConfirmationCardWindowManager?
    private let goController = GoController()
    /// The harness opens tickets; the panel and card answer them.
    private let confirmations = HarnessConfirmations(
        rulesStore: ApprovalRulesKeychainStore(),
        ignoredApprovalsFileURL: HarnessServer.ignoredLegacyApprovalsFileURL
    )
    /// One harness per process. Voice and walkthrough actions go through the same
    /// `answer(line:)` as the socket; `--harness` only adds the socket.
    private lazy var harnessServer = HarnessServer(
        globalDryRun: CommandLine.arguments.contains("--harness-dry-run"),
        confirmations: confirmations
    )

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Socket for testing Go's control layer without the AI (scripts/go-harness-smoke.py).
        if CommandLine.arguments.contains("--harness") {
            harnessServer.start()
        }

        print("🎯 Go: Starting...")
        print("🎯 Go: Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown")")

        UserDefaults.standard.register(defaults: ["NSInitialToolTipDelay": 0])
        menuBarPanelManager = MenuBarPanelManager(goController: goController, confirmations: confirmations)
        confirmationCardWindowManager = ConfirmationCardWindowManager(confirmations: confirmations)
        let sharedHarness = harnessServer
        goController.realtimeVoiceSession = RealtimeVoiceSession(harnessAnswer: { line in sharedHarness.answer(line: line) },
                                                                      speechClient: goController.elevenLabsTTSClient)
        goController.start()
        // Open the panel when onboarding or a permission still needs the user.
        if !goController.hasCompletedOnboarding || !goController.allPermissionsGranted {
            menuBarPanelManager?.showPanelOnLaunch()
        }
        registerAsLoginItemIfNeeded()
    }

    func applicationWillTerminate(_ notification: Notification) {
        goController.stop()
    }

    /// Registers Go as a login item (the user can turn it off in System Settings).
    private func registerAsLoginItemIfNeeded() {
        let loginItemService = SMAppService.mainApp
        if loginItemService.status != .enabled {
            do {
                try loginItemService.register()
                print("🎯 Go: Registered as login item")
            } catch {
                print("⚠️ Go: Failed to register as login item: \(error)")
            }
        }
    }
}
