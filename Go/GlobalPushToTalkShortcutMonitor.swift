//
//  GlobalPushToTalkShortcutMonitor.swift
//  Go
//
//  Watches for the push-to-talk shortcut system-wide with a listen-only
//  CGEvent tap, so modifier-only shortcuts like the right Option key or
//  Control + Option work.
//

import AppKit
import Carbon.HIToolbox
import Combine
import CoreGraphics
import Darwin
import Foundation

final class GlobalPushToTalkShortcutMonitor: ObservableObject {
    let shortcutTransitionPublisher = PassthroughSubject<PushToTalkShortcut.ShortcutTransition, Never>()

    private var globalEventTap: CFMachPort?
    private var globalEventTapRunLoopSource: CFRunLoopSource?
    /// Set only from the tap callback, which runs on the main run loop.
    /// Published so the overlay reacts to key release immediately.
    @Published private(set) var isShortcutCurrentlyPressed = false
    /// The keys themselves are down (before any hold delay has passed).
    private var physicallyHeld = false
    /// A press waiting out the hold delay; another key cancels it (typing, not talking).
    private var pendingPress: DispatchWorkItem?

    deinit {
        stop()
    }

    func start() {
        // Don't restart a running tap: the permission poller calls start() often,
        // and a restart would reset the pressed state mid-press.
        guard globalEventTap == nil else { return }

        let monitoredEventTypes: [CGEventType] = [.flagsChanged, .keyDown, .keyUp]
        let eventMask = monitoredEventTypes.reduce(CGEventMask(0)) { currentMask, eventType in
            currentMask | (CGEventMask(1) << eventType.rawValue)
        }

        let eventTapCallback: CGEventTapCallBack = { _, eventType, event, userInfo in
            guard let userInfo else {
                return Unmanaged.passUnretained(event)
            }

            let globalPushToTalkShortcutMonitor = Unmanaged<GlobalPushToTalkShortcutMonitor>
                .fromOpaque(userInfo)
                .takeUnretainedValue()

            return globalPushToTalkShortcutMonitor.handleGlobalEventTap(
                eventType: eventType,
                event: event
            )
        }

        guard let globalEventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: eventMask,
            callback: eventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            print("⚠️ Global push-to-talk: couldn't create CGEvent tap")
            return
        }

        guard let globalEventTapRunLoopSource = CFMachPortCreateRunLoopSource(
            kCFAllocatorDefault,
            globalEventTap,
            0
        ) else {
            CFMachPortInvalidate(globalEventTap)
            print("⚠️ Global push-to-talk: couldn't create event tap run loop source")
            return
        }

        self.globalEventTap = globalEventTap
        self.globalEventTapRunLoopSource = globalEventTapRunLoopSource

        CFRunLoopAddSource(CFRunLoopGetMain(), globalEventTapRunLoopSource, .commonModes)
        CGEvent.tapEnable(tap: globalEventTap, enable: true)
    }

    func stop() {
        isShortcutCurrentlyPressed = false
        physicallyHeld = false
        pendingPress?.cancel()
        pendingPress = nil

        if let globalEventTapRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), globalEventTapRunLoopSource, .commonModes)
            self.globalEventTapRunLoopSource = nil
        }

        if let globalEventTap {
            CFMachPortInvalidate(globalEventTap)
            self.globalEventTap = nil
        }
    }

    private func handleGlobalEventTap(
        eventType: CGEventType,
        event: CGEvent
    ) -> Unmanaged<CGEvent>? {
        if eventType == .tapDisabledByTimeout || eventType == .tapDisabledByUserInput {
            // macOS turns the tap off after a slow callback; turn it back on.
            if let globalEventTap {
                CGEvent.tapEnable(tap: globalEventTap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        let eventKeyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let option = PushToTalkShortcut.currentShortcutOption
        let shortcutTransition = PushToTalkShortcut.shortcutTransition(
            for: eventType,
            keyCode: eventKeyCode,
            modifierFlagsRawValue: event.flags.rawValue,
            wasShortcutPreviouslyPressed: physicallyHeld,
            option: option
        )

        switch shortcutTransition {
        case .none:
            // Another key while a single-key press waits: that's typing (Option + e
            // for é), not talking, so it never starts listening.
            if eventType == .keyDown, let pending = pendingPress {
                pending.cancel()
                pendingPress = nil
            }
        case .pressed:
            physicallyHeld = true
            if option.holdDelaySeconds > 0 {
                pendingPress?.cancel()
                let press = DispatchWorkItem { [weak self] in
                    guard let self, self.physicallyHeld, self.pendingPress != nil else { return }
                    self.pendingPress = nil
                    self.isShortcutCurrentlyPressed = true
                    self.shortcutTransitionPublisher.send(.pressed)
                }
                pendingPress = press
                DispatchQueue.main.asyncAfter(deadline: .now() + option.holdDelaySeconds, execute: press)
            } else {
                isShortcutCurrentlyPressed = true
                shortcutTransitionPublisher.send(.pressed)
            }
        case .released:
            physicallyHeld = false
            pendingPress?.cancel()
            pendingPress = nil
            if isShortcutCurrentlyPressed {
                isShortcutCurrentlyPressed = false
                shortcutTransitionPublisher.send(.released)
            }
        }

        return Unmanaged.passUnretained(event)
    }
}
