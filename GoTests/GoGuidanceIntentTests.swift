import Foundation
import Testing
@testable import Go

struct GoGuidanceIntentTests {
    @Test func newTasksAreRecognisedFromTheOwnersWords() {
        #expect(GoGuidanceIntent.parse("How do I create a new folder in Finder?") == .newTask("create a new folder in finder"))
        #expect(GoGuidanceIntent.parse("Walk me through exporting this vertically") == .newTask("exporting this vertically"))
        #expect(GoGuidanceIntent.parse("Can you show me how to add a project?") == .newTask("add a project"))
        #expect(GoGuidanceIntent.parse("I did it, now what?") == .continueGoal)
    }

    /// Explicit guidance wording guides; a statement or command is carried out.
    @Test func statementsAndCommandsAreDoneAndOnlyExplicitRequestsAreGuided() {
        #expect(GoGuidanceIntent.parse("Help me change the page orientation") == .doTaskForMe("change the page orientation"))
        #expect(GoGuidanceIntent.parse("I want to add a calendar event") == .doTaskForMe("add a calendar event"))
        #expect(GoGuidanceIntent.parse("I'm trying to turn on dark mode") == .doTaskForMe("turn on dark mode"))
        #expect(GoGuidanceIntent.parse("Figure out which regions are beating their sales targets and make a chart comparing them")
                == .doTaskForMe("figure out which regions are beating their sales targets and make a chart"))
        #expect(GoGuidanceIntent.parse("I need to calculate the difference between sales and target")
                == .doTaskForMe("calculate the difference between sales and target"))
        #expect(GoGuidanceIntent.parse("Let's add a column for the totals") == .doTaskForMe("add a column for the totals"))
        #expect(GoVoiceActionPolicy.allowsActions(heard: "I want to open Calendar"))
        // Negative words inside the task don't stop it; a negated request does.
        #expect(GoGuidanceIntent.parse("Filter out the regions that are not meeting targets") == .doTaskForMe("filter out the regions that are not meeting targets"))
        #expect(!GoVoiceActionPolicy.allowsActions(heard: "Don't delete anything"))
        // Explicit guidance and teaching still guide.
        #expect(GoGuidanceIntent.parse("Walk me through adding a calendar event") == .newTask("adding a calendar event"))
        #expect(GoGuidanceIntent.parse("How do I calculate the difference?") == .newTask("calculate the difference"))
        #expect(GoGuidanceIntent.parse("Show me how to make a chart") == .newTask("make a chart"))
    }

    @Test func pronounsAndNextRequestsContinueTheSavedGoal() {
        for words in ["Walk me through it", "How do I do that?", "Help me", "What's next?", "What now", "Continue", "Show me how"] {
            #expect(GoGuidanceIntent.parse(words) == .continueGoal)
        }
    }

    @Test func otherRequestsStayWithTheModel() {
        #expect(GoGuidanceIntent.parse("Where do I change the dimensions?") == .newTask("change the dimensions"))
        #expect(GoGuidanceIntent.parse("Show me where the Wi-Fi settings are") == .newTask("where the wi fi settings are"))
        #expect(GoGuidanceIntent.parse("Can you see a folder called Downloads?") == .newTask("folder called downloads"))
        #expect(GoGuidanceIntent.parse("Is there a search field?") == .newTask("search field"))
        // Direct commands are tasks Go performs itself, whatever app they concern.
        #expect(GoGuidanceIntent.parse("Can you open a photo called FT?") == .doTaskForMe("open a photo called ft"))
        #expect(GoGuidanceIntent.parse("Open Calendar") == .doTaskForMe("open calendar"))
        for words in [nil, "", "What is this?", "Stop the walkthrough", "Cancel, help me later", "Thanks, that's great"] as [String?] {
            #expect(GoGuidanceIntent.parse(words) == nil)
        }
    }

    @Test func goalRequestKeepsTheOwnersWordsWithAMatchingQuote() {
        let heard = "Walk me through exporting this vertically with captions"
        let request = GoGuidanceIntent.goalRequest(task: "exporting this vertically with captions", heard: heard)
        #expect(request.operation == .set)
        #expect(request.task == "exporting this vertically with captions")
        #expect(GoGoalRequest.matchesOwner(quote: request.sourceQuote ?? "", heard: heard))
    }

    @Test func canYouHelpMeDoItIsATaskForGo() {
        #expect(GoGuidanceIntent.parse("Can you help me figure out which regions are beating their targets and make a chart?")
                == .doTaskForMe("figure out which regions are beating their targets and make a chart"))
        #expect(GoGuidanceIntent.parse("Hey Go, could you help me rename this file to Notes") == .doTaskForMe("rename this file to notes"))
        // Learning wording still guides.
        #expect(GoGuidanceIntent.parse("Can you help me understand pivot tables?") != .doTaskForMe("understand pivot tables"))
        #expect(!GoVoiceActionPolicy.allowsActions(heard: "Can you help me learn how to make a chart?"))
    }

    @Test func guidanceWordsNeverAuthorizeActions() {
        for words in ["How do I create a new folder?", "Walk me through it", "Show me how to add a project"] {
            #expect(GoGuidanceIntent.parse(words) != nil)
            #expect(!GoVoiceActionPolicy.allowsActions(heard: words))
        }
    }
}

struct GoOffTrackTests {
    private func observation(token: String = "window-a", name: String = "Workspace", target: Bool = true,
                             complete: Bool = true) -> GoObservation {
        GoObservation(app: "org.test.any-app", windowToken: token, windowName: name, complete: complete,
                      controls: target ? [GoControl(id: "c0", role: "AXButton", name: "New", radioSelection: nil)] : [])
    }
    private var proposal: GoStepProposal {
        GoStepProposal(kind: .step, instruction: "Click New.", targetID: "c0",
                       expected: GoExpectedState(kind: .windowAppeared, role: "AXWindow", name: "Create"))
    }

    @Test func anotherWindowIsCalledOffTrackOnlyAfterItPersists() {
        var state = GoWalkthroughState()
        state.accept(proposal, from: observation())
        #expect(state.phase == .waiting)
        let first = state.noteOffTrack(observation(token: "window-b", name: "Settings"), now: 0)
        #expect(first == false)
        let early = state.noteOffTrack(observation(token: "window-b", name: "Settings"), now: 0.3)
        #expect(early == false)
        let settled = state.noteOffTrack(observation(token: "window-b", name: "Settings"), now: 0.7)
        #expect(settled == true)
        // The step stays pending so the owner can be pointed back to it, once per departure.
        #expect(state.phase == .waiting)
        let again = state.noteOffTrack(observation(token: "window-b", name: "Settings"), now: 2)
        #expect(again == false)
        _ = state.noteOffTrack(observation(), now: 3)
        _ = state.noteOffTrack(observation(token: "window-c", name: "Other"), now: 4)
        let returnedThenLeft = state.noteOffTrack(observation(token: "window-c", name: "Other"), now: 5)
        #expect(returnedThenLeft == true)
    }

    @Test func theExpectedWindowIsNeverOffTrack() {
        var state = GoWalkthroughState()
        state.accept(proposal, from: observation())
        for time in [0.0, 1.0, 2.0] {
            let offTrack = state.noteOffTrack(observation(token: "window-b", name: "Create"), now: time)
            #expect(offTrack == false)
        }
        #expect(state.phase == .waiting)
    }

    @Test func aBlipBackToTheStepResetsTheTimerAndPartialReadsNeverCount() {
        var state = GoWalkthroughState()
        state.accept(proposal, from: observation())
        _ = state.noteOffTrack(observation(token: "window-b", name: "Settings"), now: 0)
        _ = state.noteOffTrack(observation(), now: 0.4)
        let afterBlip = state.noteOffTrack(observation(token: "window-b", name: "Settings"), now: 0.8)
        #expect(afterBlip == false)
        let partial = state.noteOffTrack(observation(token: "window-b", name: "Settings", complete: false), now: 5)
        #expect(partial == false)
        #expect(state.phase == .waiting)
    }

    @Test func aVanishedTargetInTheSameWindowIsOffTrackAndTheReplyIsPrefixed() {
        var state = GoWalkthroughState()
        state.accept(proposal, from: observation())
        _ = state.noteOffTrack(observation(target: false), now: 0)
        let gone = state.noteOffTrack(observation(target: false), now: 1)
        #expect(gone == true)
        state.planning()
        state.accept(proposal, from: observation())
        state.prefixMessage("That's not quite it. ")
        #expect(state.message == "That's not quite it. Click New.")
    }
}

struct GoClickCompletionTests {
    private let before = GoObservation(app: "org.test.any-app", windowToken: "w", windowName: "Workspace", complete: true,
                                       controls: [GoControl(id: "c0", role: "AXButton", name: "New", radioSelection: nil)])
    private let step = GoStepProposal(kind: .step, instruction: "Click New.", targetID: "c0",
                                      expected: GoExpectedState(kind: .elementAppeared, role: "AXRow", name: "Untitled"))

    @Test func clickingThePointedTargetCompletesThatStepOnly() {
        var state = GoWalkthroughState()
        state.accept(step, from: before)
        guard let pending = state.step else { Issue.record("no step"); return }
        let first = state.completeByClick(pending)
        #expect(first)
        #expect(state.phase == .planning)
        #expect(state.verifiedSteps.count == 1)
        let repeated = state.completeByClick(pending)
        #expect(!repeated)
        #expect(state.verifiedSteps.count == 1)
    }

    @Test func doneNeedsAVerifiedStepFirst() {
        var state = GoWalkthroughState()
        state.accept(GoStepProposal(kind: .done, instruction: "All set.", targetID: nil, expected: nil), from: before)
        #expect(state.phase == .needsInput)
        state.accept(step, from: before)
        if let pending = state.step { _ = state.completeByClick(pending) }
        state.accept(GoStepProposal(kind: .done, instruction: "All set.", targetID: nil, expected: nil), from: before)
        #expect(state.phase == .done)
        #expect(state.message == "All set.")
        #expect(state.step == nil)
    }
}

struct GoTypingStepTests {
    private var observation: GoObservation {
        var observation = GoObservation(app: "org.test.any-app", windowToken: "w", windowName: "Save", complete: true,
                                        controls: [GoControl(id: "c0", role: "AXButton", name: "Save", radioSelection: nil)])
        observation.fields = [GoTextField(id: "t0", role: "AXTextField", label: "Name", focused: true, x: 10, y: 10, w: 200, h: 22)]
        return observation
    }

    @Test func aTypingStepTargetsTheFieldAndShowsTheText() {
        var state = GoWalkthroughState()
        state.accept(GoStepProposal(kind: .step, instruction: "Type the name in the Name field.", targetID: "t0",
                                    expected: nil, typeText: "Receipts"), from: observation)
        #expect(state.phase == .waiting)
        #expect(state.step?.field?.id == "t0")
        #expect(state.step?.typeText == "Receipts")
        #expect(state.message.contains("\u{201C}Receipts\u{201D}"))
        // Typing steps never complete from structure alone.
        let observed = state.observe(observation, now: 10)
        #expect(!observed)
    }

    @Test func aFieldStepWithoutTextLetsTheOwnerTypeTheirOwnValue() {
        // No text from the planner: the value is the owner's to choose, so Go points
        // at the field and lets them type, instead of asking what to type.
        var state = GoWalkthroughState()
        state.accept(GoStepProposal(kind: .step, instruction: "Type a name in the Name field.", targetID: "t0", expected: nil), from: observation)
        #expect(state.phase == .waiting)
        #expect(state.step?.fill == true)
        #expect(state.step?.typeText == nil)
        #expect(state.message == "Type a name in the Name field.")
    }

    @Test func quickAnswersAreSpokenNotWalkedThrough() {
        var state = GoWalkthroughState()
        state.accept(GoStepProposal(kind: .answer, instruction: "A kilobyte is 1,024 bytes.", targetID: nil, expected: nil), from: observation)
        // An answer is final: it ends the request (and its bubble clears), unlike a question.
        #expect(state.phase == .done)
        #expect(state.step == nil)
        #expect(state.message == "A kilobyte is 1,024 bytes.")
    }

    @Test func typedTextMatchingIgnoresCaseSpacingAndTrailingPunctuation() {
        #expect(GoTextFields.matches("receipts ", typeText: "Receipts"))
        #expect(GoTextFields.matches("My  Receipts 2026", typeText: "my receipts"))
        #expect(!GoTextFields.matches("Recei", typeText: "Receipts"))
        #expect(!GoTextFields.matches(nil, typeText: "Receipts"))
        #expect(!GoTextFields.matches("anything", typeText: "  "))
    }
}

struct GoPointAndRecoveryTests {
    private var observation: GoObservation {
        var observation = GoObservation(app: "org.test.any-app", windowToken: "w", windowName: "Main", complete: true,
                                        controls: [GoControl(id: "c0", role: "AXButton", name: "Share", radioSelection: nil)])
        observation.fields = [GoTextField(id: "t0", role: "AXTextField", label: "Search", focused: false, x: 0, y: 0, w: 100, h: 20)]
        return observation
    }

    @Test func aPointRequestEndsQuietlyWhenTheOwnerClicksIt() {
        var state = GoWalkthroughState()
        state.accept(GoStepProposal(kind: .point, instruction: "Here's the Share button.", targetID: "c0", expected: nil), from: observation)
        #expect(state.phase == .waiting)
        #expect(state.step?.final == true)
        guard let step = state.step else { Issue.record("no step"); return }
        let clicked = state.completeByClick(step)
        #expect(clicked)
        #expect(state.phase == .done)
        #expect(state.message.isEmpty)
        #expect(state.verifiedSteps.count == 1)
    }

    @Test func pointingAtAFieldNeedsNoTextToType() {
        var state = GoWalkthroughState()
        state.accept(GoStepProposal(kind: .point, instruction: "Here's the Search field.", targetID: "t0", expected: nil), from: observation)
        #expect(state.phase == .waiting)
        #expect(state.step?.field?.id == "t0")
        #expect(state.step?.typeText == nil)
        if let step = state.step { #expect(GoGuidePresenter.completesOnClick(step)) }
    }

    @Test func restoreReturnsToThePendingStep() {
        var state = GoWalkthroughState()
        state.accept(GoStepProposal(kind: .step, instruction: "Click Share.", targetID: "c0", expected: nil), from: observation)
        guard let step = state.step else { Issue.record("no step"); return }
        state.planning()
        state.restore(step, message: "Let's go back. Click Share.")
        #expect(state.phase == .waiting)
        #expect(state.step == step)
        #expect(state.message == "Let's go back. Click Share.")
    }
}

struct GoPhrasesTests {
    @Test func cuesRotateAndNeverRepeatBackToBack() {
        var phrases = GoPhrases()
        for kind in [GoPhrases.Kind.stepDone, .startForMe, .offTrack, .goBack, .thinking] {
            var previous = ""
            for _ in 0..<8 {
                let phrase = phrases.say(kind)
                #expect(!phrase.isEmpty)
                #expect(phrase != previous)
                #expect(phrase.split(separator: " ").count <= 6)
                previous = phrase
            }
        }
    }
}

struct GoBubbleLingerTests {
    @Test func finalMessagesClearSoonQuestionsLingerAndPendingStepsStay() {
        var answer = GoWalkthroughState()
        answer.accept(GoStepProposal(kind: .answer, instruction: "RAM stands for Random Access Memory.", targetID: nil, expected: nil),
                      from: GoObservation(app: "a", windowToken: "w", windowName: "W", complete: true, controls: []))
        let final = GoGuidePresenter.bubbleLinger(for: answer)
        #expect(final != nil && final! >= 4 && final! < 10)

        var question = GoWalkthroughState()
        question.ask("What should the folder be called? Or I can keep \u{201C}Untitled folder\u{201D}.")
        let open = GoGuidePresenter.bubbleLinger(for: question)
        #expect(open != nil && open! >= 20)

        var pending = GoWalkthroughState()
        pending.accept(GoStepProposal(kind: .step, instruction: "Click Share.", targetID: "c0", expected: nil),
                       from: GoObservation(app: "a", windowToken: "w", windowName: "W", complete: true,
                                           controls: [GoControl(id: "c0", role: "AXButton", name: "Share", radioSelection: nil)]))
        #expect(GoGuidePresenter.bubbleLinger(for: pending) == nil)
    }
}
