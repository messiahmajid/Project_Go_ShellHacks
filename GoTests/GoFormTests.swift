import CoreGraphics
import Foundation
import Testing
@testable import Go

/// Filling in a form: the owner types their own details; Go points at each field,
/// says what goes there, moves on by itself, and answers questions about a field.
@MainActor
struct GoFormTests {
    private final class Form: @unchecked Sendable {
        private let lock = NSLock()
        private var filled: Set<String> = []
        let fields = [
            GoTextField(id: "t0", role: "AXTextField", label: "Full name", focused: true, x: 10, y: 400, w: 200, h: 20),
            GoTextField(id: "t1", role: "AXTextField", label: "Email", focused: false, x: 10, y: 360, w: 200, h: 20),
            GoTextField(id: "t2", role: "AXTextField", label: "Phone", focused: false, x: 10, y: 320, w: 200, h: 20),
        ]
        func fill(_ label: String) { lock.lock(); filled.insert(label); lock.unlock() }
        func hasText(_ rect: CGRect) -> Bool {
            lock.lock(); defer { lock.unlock() }
            return fields.first { $0.frame == rect }.map { filled.contains($0.label) } ?? false
        }
        func answer(_ line: String) -> String {
            if line.contains("\"menus\"") { return #"{"ok":true,"items":[]}"# }
            let object: [String: Any] = ["ok": true, "bundleIdentifier": "org.test.form", "window": ["name": "Sign up", "token": "w"],
                "walkStopReasons": [], "focusChangedDuringWalk": false, "incompleteReads": false,
                "elements": [["role": "AXButton", "name": "Continue", "nameIsPlausibleLabel": true] as [String: Any]]]
            return String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
        }
    }

    private func goals() -> GoGoalStore {
        let store = GoGoalStore(url: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("goal.json"))
        _ = store.apply(GoGoalRequest(operation: .set, expectedRevision: 0, sourceQuote: "Help me fill in this sign-up form", task: "fill in the sign-up form"),
                        heard: "Help me fill in this sign-up form")
        return store
    }

    @Test func goMovesFromFieldToFieldWithoutPlanningEachOne() async throws {
        let form = Form()
        var plans = 0
        let coordinator = GoWalkthroughCoordinator(goals: goals(), answer: { form.answer($0) }, planner: { context in
            plans += 1
            guard context.verifiedSteps.isEmpty else {
                return GoStepProposal(kind: .point, instruction: "When you're ready, click Continue.", targetID: "c0", expected: nil)
            }
            var first = GoStepProposal(kind: .step, instruction: "You'll need your email and phone. Your full name.", targetID: "t0", expected: nil)
            first.fill = true
            first.formFields = [GoFormField(id: "t0", instruction: "Your full name."),
                                GoFormField(id: "t1", instruction: "Your email address."),
                                GoFormField(id: "t2", instruction: "Your phone number, optional.")]
            return first
        }, frontmostApp: { "org.test.form" }, fields: { _ in form.fields }, fieldHasText: { form.hasText($0) },
           logTransitions: false)
        _ = await coordinator.start()
        #expect(coordinator.state.step?.fill == true)
        #expect(coordinator.state.step?.typeText == nil)

        form.fill("Full name")
        await coordinator.targetClicked(try #require(coordinator.state.step))
        #expect(coordinator.state.step?.field?.label == "Email")
        #expect(coordinator.state.message == "Your email address.")

        form.fill("Email")
        form.fill("Phone")                                      // filled already (autofill): skipped
        await coordinator.targetClicked(try #require(coordinator.state.step))
        #expect(plans == 2)                                    // one plan for the page, one after its fields
        #expect(coordinator.state.step?.control?.name == "Continue")
    }

    @Test func unnamedFieldsAreFollowedByWhereTheySit() async throws {
        // A PDF form: no field has a name; each is known only by its position.
        final class PDFForm: @unchecked Sendable {
            private let lock = NSLock()
            private var filled: Set<Double> = []
            let fields = [
                GoTextField(id: "t0", role: "AXTextField", label: "", focused: true, x: 40, y: 700, w: 400, h: 18),
                GoTextField(id: "t1", role: "AXTextField", label: "", focused: false, x: 40, y: 660, w: 400, h: 18),
            ]
            func fill(_ index: Int) { lock.lock(); filled.insert(fields[index].y); lock.unlock() }
            func hasText(_ rect: CGRect) -> Bool { lock.lock(); defer { lock.unlock() }; return filled.contains(rect.minY) }
        }
        let form = PDFForm(), page = Form()
        var plans = 0
        let coordinator = GoWalkthroughCoordinator(goals: goals(), answer: { page.answer($0) }, planner: { _ in
            plans += 1
            var first = GoStepProposal(kind: .step, instruction: "Your name, as on your tax return.", targetID: "t0", expected: nil)
            first.fill = true
            first.formFields = [GoFormField(id: "t0", instruction: "Your name, as on your tax return."),
                                GoFormField(id: "t1", instruction: "Your business name, if it's different.")]
            return first
        }, frontmostApp: { "org.test.form" }, fields: { _ in form.fields }, fieldHasText: { form.hasText($0) },
           logTransitions: false)
        _ = await coordinator.start()
        form.fill(0)
        await coordinator.targetClicked(try #require(coordinator.state.step))
        #expect(coordinator.state.step?.field?.frame.minY == 660)             // the next box down
        #expect(coordinator.state.message == "Your business name, if it's different.")
        #expect(plans == 1)
    }

    @Test func aFieldIsTheSameByNameOrElseByPlace() {
        func field(_ label: String, _ x: Double, _ y: Double) -> GoTextField {
            GoTextField(id: "t", role: "AXTextField", label: label, focused: false, x: x, y: y, w: 200, h: 20)
        }
        #expect(GoWalkthroughCoordinator.sameField(field("Email", 0, 0), field("Email", 300, 300)))   // moved, same name
        #expect(!GoWalkthroughCoordinator.sameField(field("Email", 0, 0), field("Phone", 0, 0)))
        #expect(GoWalkthroughCoordinator.sameField(field("", 40, 700), field("", 44, 696)))          // unnamed, same place
        #expect(!GoWalkthroughCoordinator.sameField(field("", 40, 700), field("", 40, 660)))         // unnamed, another box
    }

    @Test func doItForMeHandsTheOwnersDetailsOverQuietly() async {
        let form = Form()
        var performed = 0
        let coordinator = GoWalkthroughCoordinator(goals: goals(), answer: { form.answer($0) }, planner: { _ in
            var fill = GoStepProposal(kind: .step, instruction: "Your full name.", targetID: "t0", expected: nil)
            fill.fill = true
            return fill
        }, frontmostApp: { "org.test.form" }, fields: { _ in form.fields }, fieldHasText: { form.hasText($0) },
           logTransitions: false)
        await coordinator.runForMe { _ in performed += 1; return .done }
        #expect(performed == 0)
        #expect(coordinator.state.phase == .waiting)
        #expect(coordinator.state.message == "Your full name.")   // no "I couldn't do this one"
        #expect(!coordinator.autopilot)
    }

    @Test func aQuestionAboutAFieldGetsAnAnswerAndTheStepStays() async throws {
        let form = Form()
        var asked: [String?] = []
        let coordinator = GoWalkthroughCoordinator(goals: goals(), answer: { form.answer($0) }, planner: { context in
            asked.append(context.ownerQuestion)
            if context.ownerQuestion != nil {
                #expect(context.currentStep?.contains("Your full name.") == true)
                #expect(context.screenshotJPEG == nil)          // a form's details stay on the Mac
                return GoStepProposal(kind: .answer, instruction: "Your name as it appears on your ID.", targetID: nil, expected: nil)
            }
            var fill = GoStepProposal(kind: .step, instruction: "Your full name.", targetID: "t0", expected: nil)
            fill.fill = true
            fill.formFields = [GoFormField(id: "t0", instruction: "Your full name.")]
            return fill
        }, capture: { ("/9j/", GoFrame(CGRect(x: 0, y: 0, width: 100, height: 100))) },
           frontmostApp: { "org.test.form" }, fields: { _ in form.fields }, fieldHasText: { form.hasText($0) },
           logTransitions: false)
        _ = await coordinator.start()
        let step = try #require(coordinator.state.step)
        let answer = await coordinator.answerAboutCurrentStep("Should this be my legal name?")
        #expect(answer == "Your name as it appears on your ID.")
        #expect(coordinator.state.step == step)
    }

    @Test func aFillStepFinishesOnMovingOnWithSomethingInIt() {
        #expect(!GoGuidePresenter.fillFinished(filled: true, movedOn: false))   // still typing
        #expect(!GoGuidePresenter.fillFinished(filled: false, movedOn: true))   // left it empty
        #expect(GoGuidePresenter.fillFinished(filled: true, movedOn: true))
        #expect(GoGuidePresenter.fillFinished(filled: nil, movedOn: true))      // a password box: can't be read
        var step = GoWalkthroughStep(instruction: "Your email.", app: "a", windowToken: "w", control: nil, menu: nil, expected: nil,
                                     field: GoTextField(id: "t0", role: "AXTextField", label: "Email", focused: false, x: 0, y: 0, w: 1, h: 1))
        step.fill = true
        #expect(!GoGuidePresenter.completesOnClick(step))                       // clicking into it isn't filling it
    }

    @Test func meaningQuestionsAreToldApartFromWhereQuestions() {
        for heard in ["What's a routing number?", "Do I need this one?", "Is this required?", "What format should it be?",
                      "What should I put here?", "Where do I find my member ID?"] {
            #expect(GoGuidanceIntent.asksAboutMeaning(heard, aboutField: true), "\(heard)")
        }
        #expect(!GoGuidanceIntent.asksAboutMeaning("What's the weather like?", aboutField: false))
        #expect(GoGuidanceIntent.asksAboutMeaning("What does this button do?", aboutField: false))
        #expect(!GoGuidanceIntent.asksAboutMeaning("Where is it?", aboutField: true))    // a "where" question: point again
    }
}
