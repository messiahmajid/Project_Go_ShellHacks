//
//  GoNotch.swift
//  Go
//
//  The notch: where Go shows its state (listening, working, done, needs you).
//  It grows out of the hardware camera notch, or hangs from the top centre
//  when there is none. States come only from real events: intent from the
//  model's tool call, proof only from the harness's `ok: true`. The panel is
//  click-through and never takes focus.
//

import AppKit
import AVFoundation
import Combine
import CoreAudio
import SwiftUI

// MARK: - State machine

nonisolated enum GoNotchShape: Equatable, Sendable {
    case idle
    /// Widened into the menu-bar row, with a glyph on the left.
    case compact
    /// Widened and one text line taller.
    case expanded
}

nonisolated enum GoNotchState: Hashable, Sendable {
    case idle
    case listening
    case thinking
    /// Go's own voice is playing (a step, a reply, a cue).
    case speaking
    /// Text arrives already escaped. `title` is the whole line ("Opening Finder…");
    /// `subject` is what was verified.
    case intent(title: String)
    case proof(subject: String)
    case needsYou
    case didntTake(reason: String)

    var name: String {
        switch self {
        case .idle: return "idle"
        case .listening: return "listening"
        case .thinking: return "thinking"
        case .speaking: return "speaking"
        case .intent: return "intent"
        case .proof: return "proof"
        case .needsYou: return "needsYou"
        case .didntTake: return "didntTake"
        }
    }

    var shape: GoNotchShape {
        switch self {
        case .idle: return .idle
        case .listening, .thinking, .speaking: return .compact
        case .intent, .proof, .needsYou, .didntTake: return .expanded
        }
    }

    /// Seconds before it collapses on its own; nil holds until the next event.
    var holdSeconds: Double? {
        switch self {
        case .proof: return 1.8
        case .didntTake: return 2.5
        default: return nil
        }
    }

    var title: String? {
        switch self {
        case .intent(let title): return title
        case .proof(let subject): return subject
        case .needsYou: return "Needs you"
        case .didntTake: return "Didn\u{2019}t take"
        default: return nil
        }
    }

    var detail: String? {
        switch self {
        case .proof: return " \u{2014} verified"
        case .needsYou: return " \u{2014} approve on the card"
        case .didntTake(let reason): return " \u{2014} \(reason)"
        default: return nil
        }
    }

    /// VoiceOver announces proof, needs-you and didn't-take; the rest is silent.
    var announcement: String? {
        switch self {
        case .proof(let subject): return "\(subject) verified"
        case .needsYou: return "Needs you. Approve on the card."
        case .didntTake(let reason): return "Didn\u{2019}t take. \(reason)"
        default: return nil
        }
    }

    func next(on event: GoNotchEvent) -> GoNotchState? {
        switch event {
        case .hotkeyDown:
            return .listening
        case .hotkeyUp:
            return self == .listening ? .thinking : nil
        case .firstAudioWithoutTool:
            return self == .thinking ? .idle : nil
        case .toolCall(let title):
            // A new press already owns the notch.
            return self == .listening ? nil : .intent(title: title)
        case .confirmationRequired:
            if case .intent = self { return .needsYou }
            return nil
        case .harnessAnswered(let ok, let subject, let error):
            switch self {
            case .intent, .needsYou:
                return ok ? .proof(subject: subject) : .didntTake(reason: GoNotchReason.plain(forErrorCode: error, subject: subject))
            default:
                return nil
            }
        case .holdElapsed:
            return holdSeconds == nil ? nil : .idle
        case .turnEnded:
            switch self {
            case .thinking, .intent, .needsYou: return .idle
            default: return nil
            }
        // Go's voice and Go's planning between steps show only when nothing more
        // specific (listening, an action, its result, a question) holds the notch.
        case .speechStarted:
            return self == .idle || self == .thinking ? .speaking : nil
        case .speechFinished:
            return self == .speaking ? .idle : nil
        case .planningStarted:
            return self == .idle ? .thinking : nil
        case .planningFinished:
            return self == .thinking ? .idle : nil
        }
    }
}

nonisolated enum GoNotchEvent: Equatable, Sendable {
    case hotkeyDown
    case hotkeyUp
    case firstAudioWithoutTool
    /// Before the harness request.
    case toolCall(title: String)
    /// A confirmation card is waiting.
    case confirmationRequired
    /// `ok` is the harness's own, never the model's word.
    case harnessAnswered(ok: Bool, subject: String, error: String?)
    case holdElapsed
    case turnEnded
    case speechStarted
    case speechFinished
    /// Go is working out the next step between voice turns.
    case planningStarted
    case planningFinished
}

// MARK: - Reason map

/// Harness error code to the plain words after "Didn't take —" (36 chars max,
/// tested, so the line never truncates).
nonisolated enum GoNotchReason {
    static let maximumLength = 36
    static let fallback = "it couldn\u{2019}t be verified"

    static let byErrorCode: [String: String] = [
        "notFound": "no app by that name",
        "ambiguous": "more than one app has that name",
        "missingAppName": "no app was named",
        "screenIsLocked": "the screen is locked",
        "targetIsHarnessItself": "it can\u{2019}t act on itself",
        "launchFailed": "macOS wouldn\u{2019}t launch it",
        "launchNotReady": "it never came to the front",
        "notObserved": "no change was seen",
        "frontmostChanged": "another app came forward",
        "killSwitch": "the kill switch is on",
        "kernelRefused": "refused by the safety rules",
        "policyRefused": "your policy blocks that app",
        "policyUnreadable": "the policy file is unreadable",
        "confirmationDenied": "you declined on the card",
        "confirmationExpired": "the card timed out",
        "confirmationStale": "the selection changed",
        "confirmationTicketInvalid": "the approval didn\u{2019}t match",
        "tooManyPendingConfirmations": "too many cards waiting",
        "unknownTool": "that isn\u{2019}t something I can do",
        "tooManyToolCalls": "too many tries in one turn",
        "unreadableHarnessResponse": "the harness didn\u{2019}t answer",
        "dryRun": "dry run, nothing was done",
        "notVerified": "no change was seen",
        "targetIsSubmenu": "that item opens a submenu",
        "noMenuBar": "that app has no menu bar",
        "noFrontmostApplication": "nothing is in front",
        "windowListUnreadable": "its windows didn\u{2019}t answer",
        "missingMenuPath": "no menu item was named",
        "privateMenuItem": "that menu item is private",
        "appMismatch": "a different app is in front",
        "ambiguousApp": "more than one app has that name",
        "appNotInstalled": "no app by that name",
        "heardNamedMismatch": "heard another app, asking first",
        "heardUnavailable": "didn\u{2019}t catch the app, asking",
        "heardUnconfirmed": "not sure which app, asking"
    ]

    /// `subject` is the app heard, for a heard-vs-named mismatch.
    static func plain(forErrorCode code: String?, subject: String = "") -> String {
        if code == RealtimeHeardCheck.mismatchError, !subject.isEmpty {
            let named = "heard \(subject), asking first"
            if named.count <= maximumLength { return named }
        }
        return code.flatMap { byErrorCode[$0] } ?? fallback
    }
}

// MARK: - Geometry

/// AppKit coordinates. The panel is sized once for the largest pill; the pill
/// animates inside it.
nonisolated struct GoNotchGeometry: Equatable, Sendable {
    static let wingWidth: CGFloat = 34
    static let expandedSideWidth: CGFloat = 150
    static let textBandHeight: CGFloat = 30
    static let noNotchCompactSize = CGSize(width: 68, height: 28)
    static let noNotchExpandedHeight: CGFloat = 32
    static let noNotchGap: CGFloat = 6
    /// Room around the widest pill for its shadow.
    static let margin: CGFloat = 24

    let hasNotch: Bool
    /// The hardware notch, or a point at top centre under the menu bar.
    let anchor: CGRect

    /// The notch is the gap between the two auxiliary top areas (widths only).
    static func resolve(screenFrame: CGRect, safeAreaTop: CGFloat, auxiliaryTopLeftWidth: CGFloat?,
                        auxiliaryTopRightWidth: CGFloat?, menuBarHeight: CGFloat) -> GoNotchGeometry {
        if safeAreaTop > 0, let left = auxiliaryTopLeftWidth, let right = auxiliaryTopRightWidth {
            let notchWidth = screenFrame.width - left - right
            if notchWidth > 0 {
                return GoNotchGeometry(hasNotch: true, anchor: CGRect(
                    x: screenFrame.minX + left, y: screenFrame.maxY - safeAreaTop, width: notchWidth, height: safeAreaTop))
            }
        }
        return GoNotchGeometry(hasNotch: false, anchor: CGRect(
            x: screenFrame.midX, y: screenFrame.maxY - menuBarHeight - noNotchGap, width: 0, height: 0))
    }

    func pillSize(_ shape: GoNotchShape) -> CGSize {
        switch (hasNotch, shape) {
        case (true, .idle): return anchor.size
        case (true, .compact): return CGSize(width: anchor.width + 2 * Self.wingWidth, height: anchor.height)
        case (true, .expanded):
            return CGSize(width: anchor.width + 2 * Self.expandedSideWidth, height: anchor.height + Self.textBandHeight)
        case (false, .idle): return .zero
        case (false, .compact): return Self.noNotchCompactSize
        case (false, .expanded): return CGSize(width: 2 * Self.expandedSideWidth, height: Self.noNotchExpandedHeight)
        }
    }

    var panelFrame: CGRect {
        let expanded = pillSize(.expanded)
        let width = expanded.width + 2 * Self.margin
        let height = expanded.height + Self.margin
        return CGRect(x: anchor.midX - width / 2, y: anchor.maxY - height, width: width, height: height)
    }

    /// The screen under the mouse.
    @MainActor static func forScreen(_ screen: NSScreen) -> GoNotchGeometry {
        resolve(screenFrame: screen.frame, safeAreaTop: screen.safeAreaInsets.top,
                auxiliaryTopLeftWidth: screen.auxiliaryTopLeftArea?.width,
                auxiliaryTopRightWidth: screen.auxiliaryTopRightArea?.width,
                menuBarHeight: max(0, screen.frame.maxY - screen.visibleFrame.maxY))
    }
}

// MARK: - Mic level

nonisolated enum GoNotchLevel {
    static let floorDecibels: Float = -50
    static let ceilingDecibels: Float = -10

    /// RMS to 0-1 for the bars, on a dB scale.
    static func normalised(rms: Float) -> CGFloat {
        guard rms > 0 else { return 0 }
        let decibels = 20 * log10(rms)
        return CGFloat(min(1, max(0, (decibels - floorDecibels) / (ceilingDecibels - floorDecibels))))
    }

    static func rms(_ samples: UnsafeBufferPointer<Float>) -> Float {
        guard !samples.isEmpty else { return 0 }
        return (samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count)).squareRoot()
    }

    /// Little-endian PCM16.
    static func rms(pcm16: Data) -> Float {
        let count = pcm16.count / 2
        guard count > 0 else { return 0 }
        let sumOfSquares = pcm16.withUnsafeBytes { raw in
            (0..<count).reduce(Float(0)) { sum, index in
                let sample = Float(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: index * 2, as: Int16.self))) / 32_768
                return sum + sample * sample
            }
        }
        return (sumOfSquares / Float(count)).squareRoot()
    }
}

// MARK: - Ticks

/// The press and release sounds, synthesised rather than loaded from files.
nonisolated enum GoNotchTick: CaseIterable, Sendable {
    case press
    case release

    static let sampleRate = 48_000.0

    var durationSeconds: Double { self == .press ? 0.060 : 0.045 }
    var peakDecibels: Float { self == .press ? -24 : -28 }
    private var startHertz: Double { self == .press ? 1_600 : 2_100 }
    private var endHertz: Double { self == .press ? 2_300 : 1_500 }
    private var upperPartialLevel: Double { self == .press ? 0.5 : 0.35 }

    /// Two partials gliding together, short attack, exponential decay, scaled to
    /// `peakDecibels`.
    var samples: [Float] {
        let count = Int(durationSeconds * Self.sampleRate)
        var phase = 0.0
        var output = [Float](repeating: 0, count: count)
        for index in 0..<count {
            let progress = Double(index) / Double(count)
            let frequency = startHertz + (endHertz - startHertz) * progress
            phase += 2 * Double.pi * frequency / Self.sampleRate
            let time = Double(index) / Self.sampleRate
            let envelope = min(1, time / 0.004) * exp(-progress * 5)
            output[index] = Float(envelope * (sin(phase) + upperPartialLevel * sin(1.5 * phase)))
        }
        let peak = output.map(abs).max() ?? 0
        guard peak > 0 else { return output }
        let target = pow(10, peakDecibels / 20)
        return output.map { $0 * target / peak }
    }

    /// The output device's mute switch; unreadable counts as not muted.
    static func systemOutputIsMuted() -> Bool {
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID) == noErr else { return false }
        var muted: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute,
                                             mScope: kAudioDevicePropertyScopeOutput,
                                             mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &muted) == noErr else { return false }
        return muted != 0
    }

    @MainActor func buffer(format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let samples = self.samples
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else { return nil }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        return buffer
    }
}

// MARK: - The notch

@MainActor
final class GoNotch {
    static let shared = GoNotch()

    struct Transition {
        let state: String
        let uptime: TimeInterval
    }

    private let model = GoNotchModel()
    private var panel: GoNotchPanel?
    private var generation = 0
    private(set) var state: GoNotchState = .idle
    /// The last 64, for the voice log.
    private(set) var transitions: [Transition] = []

    private init() {}

    /// Applies an event; returns the new state, or nil when it doesn't apply.
    @discardableResult
    func handle(_ event: GoNotchEvent) -> GoNotchState? {
        guard let next = state.next(on: event) else { return nil }
        if event == .hotkeyDown || panel == nil { placeOnScreenUnderCursor() }
        state = next
        generation += 1
        model.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if next != .listening && next != .speaking { model.level = 0 }
        model.state = next
        let shown = generation
        if next == .idle {
            // After the collapse animation.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                guard let self, self.generation == shown else { return }
                self.panel?.orderOut(nil)
            }
        } else {
            panel?.orderFrontRegardless()
        }
        if let seconds = next.holdSeconds {
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
                guard let self, self.generation == shown else { return }
                self.handle(.holdElapsed)
            }
        }
        if let announcement = next.announcement {
            NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested, userInfo: [
                .announcement: announcement,
                .priority: NSAccessibilityPriorityLevel.high.rawValue
            ])
        }
        transitions.append(Transition(state: next.name, uptime: ProcessInfo.processInfo.systemUptime))
        if transitions.count > 64 { transitions.removeFirst(transitions.count - 64) }
        return next
    }

    func setLevel(rms: Float) {
        guard state == .listening else { return }
        model.level = GoNotchLevel.normalised(rms: rms)
    }

    /// Go's voice level, 0-1, while speaking (nil when it can't be measured; the
    /// wave then moves on its own).
    func setSpeechLevel(_ level: CGFloat?) {
        guard state == .speaking else { return }
        model.level = level ?? -1
    }

    private func placeOnScreenUnderCursor() {
        let pointer = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(pointer, $0.frame, false) }) ?? NSScreen.main else { return }
        let geometry = GoNotchGeometry.forScreen(screen)
        let panel = self.panel ?? makePanel()
        self.panel = panel
        model.geometry = geometry
        panel.setFrame(geometry.panelFrame, display: true)
    }

    private func makePanel() -> GoNotchPanel {
        let panel = GoNotchPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                     backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        // Above the menu bar and status items, below pop-up menus.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isExcludedFromWindowsMenu = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.animationBehavior = .none
        let hostingView = NSHostingView(rootView: GoNotchView(model: model))
        // The panel's frame comes from the geometry, never the content.
        hostingView.sizingOptions = []
        panel.contentView = hostingView
        return panel
    }
}

private final class GoNotchPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

@MainActor
private final class GoNotchModel: ObservableObject {
    @Published var state: GoNotchState = .idle
    @Published var level: CGFloat = 0
    @Published var reduceMotion = false
    @Published var geometry = GoNotchGeometry(hasNotch: false, anchor: .zero)
}

// MARK: - Drawing

private enum GoNotchStyle {
    /// Go's green: the voice bars, the thinking dots and the proof ring.
    static let green = DS.Colors.accent
    static let strokeWidth: CGFloat = 1.5
    static let spring = Animation.spring(response: 0.34, dampingFraction: 0.86)
}

private struct GoNotchView: View {
    @ObservedObject var model: GoNotchModel

    var body: some View {
        let geometry = model.geometry
        let panelSize = geometry.panelFrame.size
        ZStack(alignment: .top) {
            if model.reduceMotion {
                // Each state's pill crossfades in whole.
                pill.id(model.state.shape).transition(.opacity)
            } else {
                pill
            }
        }
        .animation(model.reduceMotion ? .easeInOut(duration: 0.15) : GoNotchStyle.spring, value: model.state.shape)
        .frame(width: panelSize.width, height: panelSize.height, alignment: .top)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var pill: some View {
        let geometry = model.geometry
        let size = geometry.pillSize(model.state.shape)
        let shoulder: CGFloat = geometry.hasNotch && model.state.shape != .idle ? 6 : 0
        let bottomRadius: CGFloat = model.state.shape == .expanded ? 14 : min(10, size.height / 2)
        let outline = NotchPillShape(shoulder: shoulder, bottomRadius: bottomRadius, topRadius: geometry.hasNotch ? 0 : bottomRadius)
        return outline
            .fill(Color.black)
            .overlay {
                // Without a hardware notch to blend into, draw a faint border.
                if !geometry.hasNotch { outline.stroke(Color.white.opacity(0.08), lineWidth: 1) }
            }
            .overlay {
                if model.state == .needsYou { NeedsYouPulse(outline: outline, still: model.reduceMotion) }
            }
            .overlay { content(size: size, shoulder: shoulder) }
            .overlay(alignment: .bottom) {
                if case .proof = model.state, !model.reduceMotion {
                    ProofGlow(width: size.width).padding(.horizontal, shoulder)
                }
            }
            .clipShape(outline)
            .frame(width: size.width + 2 * shoulder, height: size.height)
            .shadow(color: geometry.hasNotch ? .clear : .black.opacity(0.35), radius: 7, x: 0, y: 4)
            .opacity(!geometry.hasNotch && model.state == .idle ? 0 : 1)
    }

    @ViewBuilder
    private func content(size: CGSize, shoulder: CGFloat) -> some View {
        let geometry = model.geometry
        switch model.state.shape {
        case .idle:
            EmptyView()
        case .compact:
            HStack(spacing: 0) {
                glyph.frame(width: geometry.hasNotch ? GoNotchGeometry.wingWidth : size.width)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, shoulder)
        case .expanded:
            VStack(spacing: 0) {
                if geometry.hasNotch { Color.clear.frame(height: geometry.anchor.height) }
                HStack(spacing: 8) {
                    glyph.frame(width: 16, height: 16)
                    line
                }
                .padding(.horizontal, 16 + shoulder)
                .frame(maxHeight: .infinity)
            }
        }
    }

    /// One identity for intent and proof, so the open arc can close into the ring.
    @ViewBuilder
    private var glyph: some View {
        switch model.state {
        case .listening:
            VoiceBars(level: model.level, still: model.reduceMotion)
        case .speaking:
            VoiceBars(level: model.level, still: model.reduceMotion)
        case .thinking:
            ThinkingDots(still: model.reduceMotion)
        case .intent, .proof:
            ArcRing(closed: { if case .proof = model.state { return true }; return false }(), still: model.reduceMotion)
        case .needsYou:
            Image(systemName: "hand.point.up.left")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.92))
        case .didntTake:
            Image(systemName: "circle.slash")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.6))
        case .idle:
            EmptyView()
        }
    }

    private var line: some View {
        (Text(model.state.title ?? "").foregroundColor(.white.opacity(0.92))
            + Text(model.state.detail ?? "").foregroundColor(.white.opacity(0.64)))
            .font(.system(size: 13, weight: .medium))
            .monospacedDigit()
            .lineLimit(1)
            .truncationMode(.middle)
            .id(model.state)
            .transition(.opacity)
            .animation(.easeInOut(duration: model.reduceMotion ? 0.15 : 0.12), value: model.state)
    }
}

/// Flat top, rounded bottom; with a notch the top corners flow out as shoulders.
private struct NotchPillShape: Shape {
    var shoulder: CGFloat
    var bottomRadius: CGFloat
    var topRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(shoulder, bottomRadius) }
        set { shoulder = newValue.first; bottomRadius = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        let left = rect.minX + shoulder, right = rect.maxX - shoulder
        let bottom = min(bottomRadius, (right - left) / 2, rect.height / 2)
        let top = min(topRadius, (right - left) / 2, rect.height / 2)
        var path = Path()
        if top > 0 {
            path.move(to: CGPoint(x: left + top, y: rect.minY))
            path.addQuadCurve(to: CGPoint(x: left, y: rect.minY + top), control: CGPoint(x: left, y: rect.minY))
        } else {
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addQuadCurve(to: CGPoint(x: left, y: rect.minY + shoulder), control: CGPoint(x: left, y: rect.minY))
        }
        path.addLine(to: CGPoint(x: left, y: rect.maxY - bottom))
        path.addQuadCurve(to: CGPoint(x: left + bottom, y: rect.maxY), control: CGPoint(x: left, y: rect.maxY))
        path.addLine(to: CGPoint(x: right - bottom, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: right, y: rect.maxY - bottom), control: CGPoint(x: right, y: rect.maxY))
        if top > 0 {
            path.addLine(to: CGPoint(x: right, y: rect.minY + top))
            path.addQuadCurve(to: CGPoint(x: right - top, y: rect.minY), control: CGPoint(x: right, y: rect.minY))
        } else {
            path.addLine(to: CGPoint(x: right, y: rect.minY + shoulder))
            path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY), control: CGPoint(x: right, y: rect.minY))
        }
        path.closeSubpath()
        return path
    }
}

/// Green bars that move with a voice: the owner's while listening, Go's while
/// speaking. Each bar ripples on its own phase, and a small breath keeps them
/// alive in pauses. A level below 0 means "can't be measured": they move on
/// their own. Static heights under Reduce Motion.
private struct VoiceBars: View {
    let level: CGFloat
    let still: Bool
    /// The middle bars lead and the outer ones follow, so it reads as a voice.
    private static let weights: [CGFloat] = [0.35, 0.6, 0.85, 1, 0.85, 0.6, 0.35]

    var body: some View {
        TimelineView(.animation(paused: still)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            let measured = level >= 0
            let base = measured ? level : 0.45 + 0.25 * CGFloat(sin(time * 3.1))
            HStack(spacing: 1.5) {
                ForEach(Self.weights.indices, id: \.self) { index in
                    let ripple = still ? 0 : CGFloat(sin(time * 9 + Double(index) * 0.9)) * (0.12 + 0.35 * base)
                    let breath = still ? 0.08 : 0.08 + 0.05 * CGFloat(sin(time * 2.2 + Double(index)))
                    let height = 3 + 13 * min(1, max(breath, base * Self.weights[index] + ripple * Self.weights[index]))
                    Capsule()
                        .fill(LinearGradient(colors: [GoNotchStyle.green, GoNotchStyle.green.opacity(0.7)],
                                             startPoint: .top, endPoint: .bottom))
                        .frame(width: 2, height: height)
                }
            }
            .frame(height: 16)
            .shadow(color: GoNotchStyle.green.opacity(0.55), radius: 3)
        }
        .animation(.easeOut(duration: 0.08), value: level)
    }
}

/// Three green dots bouncing in turn while Go works out what to do.
private struct ThinkingDots: View {
    let still: Bool

    var body: some View {
        TimelineView(.animation(paused: still)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 3) {
                ForEach(0..<3, id: \.self) { index in
                    let wave = still ? 0 : max(0, sin(time * 5 - Double(index) * 0.8))
                    Circle()
                        .fill(GoNotchStyle.green.opacity(0.55 + 0.45 * wave))
                        .frame(width: 4, height: 4)
                        .offset(y: -3 * wave)
                }
            }
            .frame(height: 12)
            .shadow(color: GoNotchStyle.green.opacity(0.4), radius: 2)
        }
    }
}

/// An open arc that turns while the harness works, then closes into a green
/// ring when verified.
private struct ArcRing: View {
    let closed: Bool
    let still: Bool

    var body: some View {
        TimelineView(.animation(paused: closed || still)) { context in
            let degrees = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2.4) / 2.4 * 360
            ZStack {
                Circle()
                    .fill(GoNotchStyle.green)
                    .scaleEffect(closed ? 0.62 : 0.2)
                    .opacity(closed ? 1 : 0)
                Circle()
                    .trim(from: 0, to: closed ? 1 : 0.72)
                    .stroke(closed ? GoNotchStyle.green : Color.white.opacity(0.7),
                            style: StrokeStyle(lineWidth: GoNotchStyle.strokeWidth, lineCap: .round))
                    .rotationEffect(.degrees(closed || still ? -90 : degrees))
            }
            .frame(width: 14, height: 14)
        }
        .animation(still ? nil : .easeOut(duration: 0.45), value: closed)
    }
}

private struct ProofGlow: View {
    let width: CGFloat
    @State private var progress: CGFloat = 0

    var body: some View {
        Capsule()
            .fill(GoNotchStyle.green)
            .frame(width: 56, height: 2)
            .blur(radius: 2.5)
            .modifier(TravelAlongEdge(progress: progress, width: width))
            .onAppear { withAnimation(.easeInOut(duration: 0.6)) { progress = 1 } }
    }
}

private struct TravelAlongEdge: ViewModifier, Animatable {
    var progress: CGFloat
    let width: CGFloat
    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        content
            .offset(x: (progress - 0.5) * (width - 40))
            .opacity(Double(sin(progress * .pi)))
    }
}

/// A slow outline pulse while the card waits; static under Reduce Motion.
private struct NeedsYouPulse: View {
    let outline: NotchPillShape
    let still: Bool
    @State private var bright = false

    var body: some View {
        outline
            .stroke(Color.white.opacity(0.4), lineWidth: 1)
            .opacity(still ? 1 : (bright ? 1 : 0.25))
            .onAppear {
                guard !still else { return }
                withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) { bright = true }
            }
    }
}
