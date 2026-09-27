import CoreGraphics
import Foundation
import Testing
@testable import Go

/// Real runs, saved as test cases (see `GoRunRecorder`), replayed through Go's
/// own step logic: a change in how Go turns a real planner answer into a step
/// fails here before it reaches a live test. For an intended change, run the
/// tests with TEST_RUNNER_GO_REBASELINE=1 to accept the new results.
struct GoRecordedRunTests {
    @Test func savedRunsStillBecomeTheSameSteps() {
        let rebaseline = ProcessInfo.processInfo.environment["GO_REBASELINE"] == "1"
        for (name, recorded) in GoRunRecorder.saved() {
            let now = GoRunRecorder.replay(recorded)
            if rebaseline, now != recorded.outcome {
                GoRunRecorder.rebaseline(name, to: now)
                continue
            }
            #expect(now == recorded.outcome, "\(name) (\(recorded.observation.app)): was \(recorded.outcome), now \(now)")
        }
    }

    @Test func aCaseReplaysTheWayItWasRecorded() throws {
        var observation = GoObservation(app: "any.app", windowToken: "w", windowName: "Main", complete: true,
                                        controls: [GoControl(id: "c0", role: "AXButton", name: "Insert", radioSelection: nil)])
        observation.screenFrame = GoFrame(CGRect(x: 0, y: 0, width: 800, height: 600))
        let goal = GoGoal(id: UUID(), rawGoal: "Insert a chart", lastInstruction: "Insert a chart", task: "insert a chart", status: .active)
        let context = GoPlanningContext(goal: goal, observation: observation, verifiedSteps: [], catalogLimited: false)
        for proposal in [GoStepProposal(kind: .step, instruction: "Click Insert.", targetID: "c0", expected: nil),
                         GoStepProposal(kind: .step, instruction: "Click it.", targetID: "screen", expected: nil, box: [0, 0, 1000, 1000])] {
            var state = GoWalkthroughState()
            state.accept(proposal, from: observation)
            let recorded = GoRunRecorder.Case(recordedAt: Date(), context: context, observation: observation,
                                              proposal: proposal, outcome: GoRunRecorder.Outcome(state))
            let reloaded = try JSONDecoder().decode(GoRunRecorder.Case.self, from: JSONEncoder().encode(recorded))
            #expect(GoRunRecorder.replay(reloaded) == recorded.outcome)
        }
        // What a rejected box records: a question, with Go's own reason.
        var state = GoWalkthroughState()
        state.accept(GoStepProposal(kind: .step, instruction: "Click it.", targetID: "screen", expected: nil, box: [0, 0, 1000, 1000]),
                     from: observation)
        #expect(GoRunRecorder.Outcome(state) == GoRunRecorder.Outcome(phase: "needsInput", stepKind: nil, target: nil, askCode: "boxRejected"))
    }
}
