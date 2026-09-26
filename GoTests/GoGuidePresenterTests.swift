import Foundation
import CoreGraphics
import Testing
@testable import Go

@MainActor
struct GoGuidePresenterTests {
    private func step(_ text: String = "Select Choice.") -> GoWalkthroughState {
        var state = GoWalkthroughState()
        state.accept(GoStepProposal(kind: .step, instruction: text, targetID: "c0",
            expected: GoExpectedState(kind: .radioSelected, role: "AXRadioButton", name: "Choice")),
            from: GoObservation(app: "test.app", windowToken: "one", windowName: "Panel", complete: true,
                controls: [GoControl(id: "c0", role: "AXRadioButton", name: "Choice", radioSelection: false)]))
        return state
    }

    @Test func theHighlightFollowsTheTargetAndHidesWhileItIsOffScreen() async throws {
        let first = CGRect(x: 100, y: 100, width: 40, height: 20)
        let moved = CGRect(x: 300, y: 100, width: 40, height: 20)
        let whereItIs = TestBox<CGRect?>(first)
        var highlights: [CGRect?] = []
        let presenter = GoGuidePresenter(resolve: { _ in first }, speak: { _ in }, stopSpeech: {}, showText: { _ in },
            point: { _, _ in }, stillWaiting: { _ in true },
            locate: { _ in whereItIs.value }, highlight: { highlights.append($0) })
        presenter.present(step(), spoken: false)
        try await Task.sleep(for: .milliseconds(700))
        #expect(highlights.isEmpty)                 // unchanged target: nothing redrawn
        whereItIs.value = nil                        // a wrong click took it off screen
        try await Task.sleep(for: .milliseconds(700))
        #expect(highlights.last == .some(nil))      // the stale highlight is hidden
        whereItIs.value = moved                      // back again, somewhere else
        try await Task.sleep(for: .milliseconds(700))
        #expect(highlights.last == .some(moved))    // and redrawn where it is now
        presenter.cancel()
    }

    @Test func fixedPositionTargetsFollowAWindowMoveAndHideOnResize() {
        let field = CGRect(x: 120, y: 300, width: 200, height: 22)
        let window = CGRect(x: 100, y: 100, width: 800, height: 600)
        // Moved 50 right and 30 up: the field goes with it.
        #expect(GoGuidePresenter.followWindow(field, planned: window, now: window.offsetBy(dx: 50, dy: 30))
                == field.offsetBy(dx: 50, dy: 30))
        // Resized: the layout may have reflowed, so no guess.
        #expect(GoGuidePresenter.followWindow(field, planned: window,
                now: CGRect(x: 100, y: 100, width: 1000, height: 600)) == nil)
        // Unknown frames: nothing to compare, keep the frame.
        #expect(GoGuidePresenter.followWindow(field, planned: nil, now: window) == field)
    }

    @Test func theObservationRecordsItsWindowFrame() {
        let object: [String: Any] = ["ok": true, "bundleIdentifier": "any.app",
            "window": ["name": "W", "token": "1", "frame": ["x": 10.0, "y": 20.0, "w": 800.0, "h": 600.0]],
            "walkStopReasons": [], "focusChangedDuringWalk": false, "incompleteReads": false, "elements": []]
        #expect(GoObservation.decode(object)?.windowFrame?.rect == CGRect(x: 10, y: 20, width: 800, height: 600))
    }

    @Test func automaticInstructionUsesTheSameTextForSpeechAndPointing() async {
        var spoken: [String] = [], visible: [String] = [], pointed: [String] = []
        let presenter = GoGuidePresenter(resolve: { _ in CGRect(x: 1, y: 2, width: 30, height: 20) },
            speak: { spoken.append($0) }, stopSpeech: {}, showText: { if let text = $0 { visible.append(text) } },
            point: { rect, text in if rect != nil { pointed.append(text) } })
        presenter.present(step(), spoken: true)
        for _ in 0..<100 where spoken.isEmpty { await Task.yield() }
        #expect(spoken == ["Select Choice."])
        #expect(visible == spoken)
        #expect(pointed == spoken)
        presenter.cancel()
    }

    @Test func interruptionPreventsLatePointingAndSpeech() async {
        var pending: CheckedContinuation<CGRect?, Never>?
        let cancelled = TestBox(false)
        var spokeAfterCancel = false, stopped = false, pointed = false
        // Speech now starts alongside pointing; an interruption must stop it and prevent anything late.
        let presenter = GoGuidePresenter(resolve: { _ in await withCheckedContinuation { pending = $0 } },
            speak: { _ in if cancelled.value { spokeAfterCancel = true } }, stopSpeech: { stopped = true }, showText: { _ in },
            point: { rect, _ in if rect != nil { pointed = true } })
        presenter.present(step(), spoken: true)
        for _ in 0..<100 where pending == nil { await Task.yield() }
        #expect(pending != nil)
        cancelled.value = true
        presenter.cancel()
        pending?.resume(returning: CGRect(x: 1, y: 2, width: 30, height: 20))
        for _ in 0..<10 { await Task.yield() }
        #expect(stopped)
        #expect(!spokeAfterCancel)
        #expect(!pointed)
    }

    @Test func initialInstructionIsVisualOnlyAndSpeechFailureKeepsText() async {
        var spoken = 0
        var visible: String?
        let presenter = GoGuidePresenter(resolve: { _ in nil }, speak: { _ in
            spoken += 1
            throw CancellationError()
        }, stopSpeech: {}, showText: { visible = $0 }, point: { _, _ in })
        presenter.present(step(), spoken: false)
        for _ in 0..<10 { await Task.yield() }
        #expect(spoken == 0)
        var question = GoWalkthroughState()
        question.ask("The dialog is open. What name would you like?")
        presenter.present(question, spoken: true)
        for _ in 0..<100 where spoken == 0 { await Task.yield() }
        #expect(spoken == 1)
        #expect(visible == question.message)
        presenter.cancel()
    }

    @Test func invalidFramesCannotBecomeCursorLocations() {
        #expect(GoGuidePresenter.rect(["x": 1.0, "y": 2.0, "w": 30.0, "h": 20.0]) != nil)
        #expect(GoGuidePresenter.rect(["x": Double.nan, "y": 2.0, "w": 30.0, "h": 20.0]) == nil)
        #expect(GoGuidePresenter.rect(["x": 1.0, "y": 2.0, "w": -30.0, "h": 20.0]) == nil)
    }

    @Test func aSystemPanelWithFocusIsTheActiveAppAndGoNeverIs() {
        // Control Center takes focus while Xcode stays "frontmost".
        #expect(GoActiveApp.choose(focused: "com.apple.controlcenter", frontmost: "com.apple.dt.Xcode", own: "go") == "com.apple.controlcenter")
        // Go's own panel holding focus: the app behind it.
        #expect(GoActiveApp.choose(focused: "go", frontmost: "com.apple.finder", own: "go") == "com.apple.finder")
        #expect(GoActiveApp.choose(focused: nil, frontmost: "com.apple.finder", own: "go") == "com.apple.finder")
        #expect(GoActiveApp.choose(focused: "go", frontmost: "go", own: "go") == nil)
    }

    @Test func openingTheNamedAppFinishesALaunchStepAndNothingElseDoes() {
        let launch = GoWalkthroughStep(instruction: "Open Spotify.", app: "com.apple.dt.Xcode", windowToken: "w", control: nil,
                                       menu: nil, expected: nil, launchApp: "Spotify")
        #expect(GoGuidePresenter.activationFinishes(launch, activated: "com.spotify.client", name: "Spotify"))
        #expect(!GoGuidePresenter.activationFinishes(launch, activated: "com.apple.Safari", name: "Safari"))
        #expect(!GoGuidePresenter.activationFinishes(launch, activated: "com.apple.dt.Xcode", name: "Xcode"))
        var opens = GoWalkthroughStep(instruction: "Open the photo.", app: "com.apple.finder", windowToken: "w", control: nil,
                                      menu: nil, expected: nil)
        opens.opens = true
        #expect(GoGuidePresenter.activationFinishes(opens, activated: "com.apple.Preview", name: "Preview"))
    }
}
