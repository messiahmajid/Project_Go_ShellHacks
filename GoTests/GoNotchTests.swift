//
//  GoNotchTests.swift
//  GoTests
//
//  The notch's pure parts: state machine, error-code reasons, geometry with and
//  without a hardware notch, mic level and ticks.
//

import CoreGraphics
import Foundation
import Testing
@testable import Go

struct GoNotchTests {

    // MARK: State machine

    @Test func aVerifiedOpenRunsListeningThinkingIntentProofIdle() {
        var state = GoNotchState.idle
        let events: [GoNotchEvent] = [
            .hotkeyDown, .hotkeyUp, .toolCall(title: "System Settings"),
            .harnessAnswered(ok: true, subject: "System Settings", error: nil), .holdElapsed
        ]
        var names: [String] = []
        for event in events {
            state = state.next(on: event) ?? state
            names.append(state.name)
        }
        #expect(names == ["listening", "thinking", "intent", "proof", "idle"])
    }

    @Test func proofComesOnlyFromAnOkAnswerAfterAnIntent() {
        let ok = GoNotchEvent.harnessAnswered(ok: true, subject: "Finder", error: nil)
        #expect(GoNotchState.intent(title: "Finder").next(on: ok) == .proof(subject: "Finder"))
        #expect(GoNotchState.needsYou.next(on: ok) == .proof(subject: "Finder"))
        // No intent on screen, no proof: a late answer after a new press or after idle moves nothing.
        for state: GoNotchState in [.idle, .listening, .thinking, .didntTake(reason: "x")] {
            #expect(state.next(on: ok) == nil)
        }
        let failed = GoNotchEvent.harnessAnswered(ok: false, subject: "Figma", error: "notFound")
        #expect(GoNotchState.intent(title: "Figma").next(on: failed) == .didntTake(reason: "no app by that name"))
    }

    @Test func aTicketHoldsNeedsYouUntilItIsAnswered() {
        let intent = GoNotchState.intent(title: "Terminal")
        #expect(intent.next(on: .confirmationRequired) == .needsYou)
        #expect(GoNotchState.needsYou.holdSeconds == nil)
        #expect(GoNotchState.needsYou.next(on: .holdElapsed) == nil)
        #expect(GoNotchState.needsYou.next(on: .harnessAnswered(ok: false, subject: "Terminal", error: "confirmationDenied"))
                == .didntTake(reason: "you declined on the card"))
        #expect(GoNotchState.thinking.next(on: .confirmationRequired) == nil)
    }

    @Test func eventsOutsideTheirStateAreIgnored() {
        #expect(GoNotchState.thinking.next(on: .hotkeyUp) == nil)
        #expect(GoNotchState.listening.next(on: .toolCall(title: "x")) == nil)
        #expect(GoNotchState.thinking.next(on: .firstAudioWithoutTool) == .idle)
        #expect(GoNotchState.intent(title: "x").next(on: .firstAudioWithoutTool) == nil)
        #expect(GoNotchState.proof(subject: "x").next(on: .turnEnded) == nil)
        #expect(GoNotchState.intent(title: "x").next(on: .turnEnded) == .idle)
        // A press always wins, whatever is showing.
        #expect(GoNotchState.proof(subject: "x").next(on: .hotkeyDown) == .listening)
    }

    @Test func shapesHoldsAndAnnouncementsMatchTheContract() {
        #expect(GoNotchState.idle.shape == .idle)
        #expect(GoNotchState.listening.shape == .compact)
        #expect(GoNotchState.thinking.shape == .compact)
        #expect(GoNotchState.intent(title: "x").shape == .expanded)
        #expect(GoNotchState.proof(subject: "x").holdSeconds == 1.8)
        #expect(GoNotchState.didntTake(reason: "x").holdSeconds == 2.5)
        #expect(GoNotchState.intent(title: "Opening Finder\u{2026}").title == "Opening Finder\u{2026}")
        #expect(GoNotchState.proof(subject: "System Settings").detail == " \u{2014} verified")
        // VoiceOver: proof, needs you, didn't take — never listening, thinking or intent.
        #expect(GoNotchState.listening.announcement == nil)
        #expect(GoNotchState.thinking.announcement == nil)
        #expect(GoNotchState.intent(title: "x").announcement == nil)
        #expect(GoNotchState.proof(subject: "Finder").announcement == "Finder verified")
        #expect(GoNotchState.needsYou.announcement != nil)
        #expect(GoNotchState.didntTake(reason: "x").announcement != nil)
    }

    // MARK: Reason map

    @Test func everyReasonFitsTheLine() {
        for reason in Array(GoNotchReason.byErrorCode.values) + [GoNotchReason.fallback] {
            #expect(!reason.isEmpty)
            #expect(reason.count <= GoNotchReason.maximumLength, "\(reason)")
        }
        #expect(GoNotchReason.plain(forErrorCode: "notFound") == "no app by that name")
        #expect(GoNotchReason.plain(forErrorCode: "appMismatch") == "a different app is in front")
        #expect(GoNotchReason.plain(forErrorCode: "ambiguousApp") == "more than one app has that name")
        #expect(GoNotchReason.plain(forErrorCode: "somethingNew") == GoNotchReason.fallback)
        #expect(GoNotchReason.plain(forErrorCode: nil) == GoNotchReason.fallback)
    }

    // MARK: Geometry

    /// A 14" MacBook Pro at default scale: 1512x982 pt, a 32 pt menu bar, the
    /// notch 185 pt wide between two 663.5 pt auxiliary areas.
    @Test func withANotchThePillGrowsOutOfIt() {
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let geometry = GoNotchGeometry.resolve(screenFrame: screen, safeAreaTop: 32, auxiliaryTopLeftWidth: 663.5,
                                                   auxiliaryTopRightWidth: 663.5, menuBarHeight: 32)
        #expect(geometry.hasNotch)
        #expect(geometry.anchor == CGRect(x: 663.5, y: 950, width: 185, height: 32))
        #expect(geometry.pillSize(.idle) == CGSize(width: 185, height: 32))
        #expect(geometry.pillSize(.compact) == CGSize(width: 185 + 68, height: 32))
        #expect(geometry.pillSize(.expanded) == CGSize(width: 185 + 300, height: 62))
        // Top edge on the screen's top edge, centred on the notch.
        #expect(geometry.panelFrame.maxY == 982)
        #expect(geometry.panelFrame.midX == 756)
        #expect(geometry.panelFrame.width >= geometry.pillSize(.expanded).width)
    }

    @Test func withoutANotchThePillHangsUnderTheMenuBar() {
        // A second display to the right, origin not zero.
        let screen = CGRect(x: 1512, y: -100, width: 1920, height: 1080)
        let geometry = GoNotchGeometry.resolve(screenFrame: screen, safeAreaTop: 0, auxiliaryTopLeftWidth: nil,
                                                   auxiliaryTopRightWidth: nil, menuBarHeight: 24)
        #expect(!geometry.hasNotch)
        #expect(geometry.anchor.midX == screen.midX)
        #expect(geometry.anchor.maxY == screen.maxY - 24 - GoNotchGeometry.noNotchGap)
        #expect(geometry.pillSize(.idle) == .zero)
        #expect(geometry.pillSize(.compact) == GoNotchGeometry.noNotchCompactSize)
        #expect(geometry.panelFrame.maxY == geometry.anchor.maxY)
        // Auxiliary areas that leave no gap are not a notch.
        let noGap = GoNotchGeometry.resolve(screenFrame: screen, safeAreaTop: 24, auxiliaryTopLeftWidth: 960,
                                                auxiliaryTopRightWidth: 960, menuBarHeight: 24)
        #expect(!noGap.hasNotch)
    }

    // MARK: Level

    @Test func levelMapsDecibelsOntoTheBars() {
        #expect(GoNotchLevel.normalised(rms: 0) == 0)
        #expect(GoNotchLevel.normalised(rms: pow(10, -60 / 20)) == 0)
        #expect(abs(GoNotchLevel.normalised(rms: pow(10, -30 / 20)) - 0.5) < 0.001)
        #expect(GoNotchLevel.normalised(rms: 1) == 1)
        // A full-scale square wave has RMS 1.
        var square = Data()
        for index in 0..<100 {
            let sample: Int16 = index % 2 == 0 ? 32_767 : -32_767
            withUnsafeBytes(of: sample.littleEndian) { square.append(contentsOf: $0) }
        }
        #expect(abs(GoNotchLevel.rms(pcm16: square) - 1) < 0.001)
        #expect(GoNotchLevel.rms(pcm16: Data()) == 0)
    }

    // MARK: Ticks

    @Test func ticksAreShortSoftAndPitchedTheRightWay() {
        func peakDecibels(_ samples: [Float]) -> Float { 20 * log10(samples.map(abs).max() ?? 0) }
        /// Zero crossings per sample over a stretch — a pitch proxy.
        func crossingRate(_ samples: ArraySlice<Float>) -> Double {
            Double(zip(samples, samples.dropFirst()).filter { ($0 < 0) != ($1 < 0) }.count) / Double(samples.count)
        }
        for tick in GoNotchTick.allCases {
            let samples = tick.samples
            let milliseconds = Double(samples.count) / GoNotchTick.sampleRate * 1000
            #expect((40...70).contains(milliseconds))
            #expect(abs(peakDecibels(samples) - tick.peakDecibels) < 0.1)
        }
        #expect(GoNotchTick.press.peakDecibels == -24)
        #expect(GoNotchTick.release.peakDecibels < GoNotchTick.press.peakDecibels)
        let press = GoNotchTick.press.samples, release = GoNotchTick.release.samples
        #expect(crossingRate(press[(press.count / 2)...]) > crossingRate(press[..<(press.count / 2)]))
        #expect(crossingRate(release[(release.count / 2)...]) < crossingRate(release[..<(release.count / 2)]))
    }
}
