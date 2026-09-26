import Foundation
import Testing
@testable import Go

struct GoWalkthroughTests {
    private func observation(app: String = "org.test.any-app", token: String = "window-a", complete: Bool = true,
                             selected: Bool = false, extra: Bool = false) -> GoObservation {
        GoObservation(app: app, windowToken: token, windowName: "Workspace", complete: complete,
                      controls: [GoControl(id: "c0", role: "AXRadioButton", name: "Choice", radioSelection: selected)] +
                        (extra ? [GoControl(id: "c1", role: "AXButton", name: "Continue", radioSelection: nil)] : []))
    }
    private var proposal: GoStepProposal {
        GoStepProposal(kind: .step, instruction: "Select Choice.", targetID: "c0",
                       expected: GoExpectedState(kind: .radioSelected, role: "AXRadioButton", name: "Choice"))
    }

    @Test func selectionNeedsFreshStableEvidenceInTheSameAppAndWindow() {
        var state = GoWalkthroughState()
        state.accept(proposal, from: observation())
        #expect(state.phase == .waiting)
        let observed1 = state.observe(observation(extra: true), now: 0)
        #expect(observed1 == false)
        let observed2 = state.observe(observation(app: "org.test.other", selected: true), now: 1)
        #expect(observed2 == false)
        let observed3 = state.observe(observation(token: "other-window", selected: true), now: 2)
        #expect(observed3 == false)
        let observed4 = state.observe(observation(complete: false, selected: true), now: 3)
        #expect(observed4 == false)
        let observed5 = state.observe(observation(selected: true), now: 4)
        #expect(observed5 == false)
        let observed6 = state.observe(observation(selected: true), now: 4.1)
        #expect(observed6 == false)
        let observed7 = state.observe(observation(selected: true), now: 4.3)
        #expect(observed7 == true)
        #expect(state.phase == .planning)
        #expect(state.verifiedSteps.count == 1)
        let observed8 = state.observe(observation(selected: true), now: 5)
        #expect(observed8 == false)
        #expect(state.verifiedSteps.count == 1)
    }

    @Test func unknownDuplicateAndAlreadySatisfiedTargetsCannotBecomeSteps() {
        var state = GoWalkthroughState()
        // A prediction that already holds is dropped; the step still waits for the owner's click.
        state.accept(proposal, from: observation(selected: true))
        #expect(state.phase == .waiting)
        #expect(state.step?.expected == nil)
        let duplicate = GoObservation(app: "any", windowToken: "a", windowName: "A", complete: true,
            controls: [GoControl(id: "c0", role: "AXRadioButton", name: "Choice", radioSelection: false),
                       GoControl(id: "c2", role: "AXRadioButton", name: "Choice", radioSelection: false)])
        state.accept(proposal, from: duplicate)
        #expect(state.phase == .needsInput)
        state.accept(GoStepProposal(kind: .step, instruction: "Select it.", targetID: "invented", expected: proposal.expected), from: observation())
        #expect(state.phase == .needsInput)
    }

    @Test func aTransientMatchDoesNotAdvanceAndWindowChangesDoNotProveAbsence() {
        var state = GoWalkthroughState()
        state.accept(proposal, from: observation())
        let observed9 = state.observe(observation(selected: true), now: 0)
        #expect(observed9 == false)
        let observed10 = state.observe(observation(), now: 0.2)
        #expect(observed10 == false)
        let observed11 = state.observe(observation(selected: true), now: 0.4)
        #expect(observed11 == false)
        let observed12 = state.observe(observation(selected: true), now: 0.5)
        #expect(observed12 == false)
        let disappear = GoStepProposal(kind: .step, instruction: "Close Continue.", targetID: "c1",
            expected: GoExpectedState(kind: .elementDisappeared, role: "AXButton", name: "Continue"))
        state.accept(disappear, from: observation(extra: true))
        let observed13 = state.observe(observation(token: "other"), now: 1)
        #expect(observed13 == false)
        let observed14 = state.observe(observation(token: "other"), now: 2)
        #expect(observed14 == false)
        #expect(state.verifiedSteps.isEmpty)
    }

    @Test func decodesOnlyLabelledControlsAndPreservesIncompleteEvidence() {
        let object: [String: Any] = ["ok": true, "bundleIdentifier": "any.app", "window": ["name": "Window", "token": "1"],
            "walkStopReasons": [], "focusChangedDuringWalk": false, "incompleteReads": true,
            "elements": [["role": "AXSecureTextField", "name": "secret", "nameIsPlausibleLabel": true],
                         ["role": "AXButton", "name": "Next", "nameIsPlausibleLabel": true],
                         ["role": "AXTextArea", "name": "document contents", "nameIsPlausibleLabel": true]]]
        let result = GoObservation.decode(object)
        #expect(result?.controls.map(\.name) == ["Next"])
        #expect(result?.complete == false)
    }
}

@MainActor
struct GoWalkthroughCoordinatorTests {
    private final class Harness: @unchecked Sendable {
        private let lock = NSLock()
        private var stage = 0
        func setStage(_ stage: Int) { lock.lock(); defer { lock.unlock() }; self.stage = stage }
        func answer(_ line: String) -> String {
            lock.lock(); defer { lock.unlock() }
            if line.contains("menus") { return #"{"ok":true,"items":[]}"# }
            var names = ["Open"]
            if stage >= 1 { names.append("Continue") }
            let object: [String: Any] = ["ok": true, "bundleIdentifier": "org.test.arbitrary-app",
                "window": ["name": "Workspace", "token": "one"], "walkStopReasons": [],
                "focusChangedDuringWalk": false, "incompleteReads": false,
                "elements": names.map { ["role": "AXButton", "name": $0, "nameIsPlausibleLabel": true] as [String: Any] }]
            return String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
        }
    }

    @Test func verificationAutomaticallyRequestsTheNextStepWithoutAnOwnerTurn() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let goals = GoGoalStore(url: directory.appendingPathComponent("goal.json"))
        _ = goals.apply(GoGoalRequest(operation: .set, expectedRevision: 0, sourceQuote: "Help me continue", task: "continue_task"), heard: "Help me continue")
        let harness = Harness()
        var calls = 0
        let clock = TestBox<TimeInterval>(0)
        let coordinator = GoWalkthroughCoordinator(goals: goals, answer: { harness.answer($0) }, planner: { context in
            calls += 1
            if calls == 1 {
                #expect(context.verifiedSteps.isEmpty)
                return GoStepProposal(kind: .step, instruction: "Press Open.", targetID: "c0",
                    expected: GoExpectedState(kind: .elementAppeared, role: "AXButton", name: "Continue"))
            }
            #expect(context.verifiedSteps.count == 1)
            #expect(context.observation.controls.contains { $0.name == "Continue" })
            return GoStepProposal(kind: .ask, instruction: "What would you like to do here?", targetID: nil, expected: nil)
        }, frontmostApp: { "org.test.arbitrary-app" }, now: { clock.value }, logTransitions: false)
        var spoken: [String] = []
        let guide = GoGuidePresenter(resolve: { _ in nil }, speak: { spoken.append($0) },
            stopSpeech: {}, showText: { _ in }, point: { _, _ in })
        coordinator.onChange = { state in guide.present(state, spoken: true) }
        defer { coordinator.stop() }
        _ = await coordinator.start()
        for _ in 0..<100 where spoken.isEmpty { await Task.yield() }
        #expect(spoken == ["Press Open."])
        #expect(coordinator.state.phase == .waiting)
        await coordinator.refresh()
        #expect(calls == 1)
        // A user can pause to ask questions before following the instruction.
        // Time alone must neither complete nor abandon the pending step.
        clock.value = 600
        await coordinator.refresh()
        #expect(coordinator.state.phase == .waiting)
        #expect(coordinator.state.verifiedSteps.isEmpty)
        #expect(calls == 1)
        harness.setStage(1)
        await coordinator.refresh()
        clock.value = 600.3
        await coordinator.refresh()
        #expect(calls == 2)
        #expect(coordinator.state.verifiedSteps.count == 1)
        #expect(coordinator.state.phase == .needsInput)
        for _ in 0..<100 where spoken.count < 2 { await Task.yield() }
        // The acknowledgement for a completed step is spoken by the session the moment
        // it completes, so the next instruction itself carries no prefix.
        #expect(spoken == ["Press Open.", "What would you like to do here?"])
    }

    @Test func changedGoalCannotAcceptAnOldPlannerAnswer() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let goals = GoGoalStore(url: directory.appendingPathComponent("goal.json"))
        _ = goals.apply(GoGoalRequest(operation: .set, expectedRevision: 0, sourceQuote: "First goal", task: "first"), heard: "First goal")
        let harness = Harness()
        let coordinator = GoWalkthroughCoordinator(goals: goals, answer: { harness.answer($0) }, planner: { _ in
            _ = goals.apply(GoGoalRequest(operation: .clear, expectedRevision: 1, sourceQuote: "Forget it"), heard: "Forget it")
            return GoStepProposal(kind: .step, instruction: "Press Open.", targetID: "c0",
                expected: GoExpectedState(kind: .elementAppeared, role: "AXButton", name: "Continue"))
        }, logTransitions: false)
        defer { coordinator.stop() }
        _ = await coordinator.start()
        #expect(coordinator.state.step == nil)
        #expect(coordinator.state.verifiedSteps.isEmpty)
        coordinator.resume()
        #expect(coordinator.state.phase == .stopped)
    }
}

/// A mutable value shared with closures in tests.
final class TestBox<Value>: @unchecked Sendable {
    var value: Value
    init(_ value: Value) { self.value = value }
}
