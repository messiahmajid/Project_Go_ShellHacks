import CoreGraphics
import Foundation
import Testing
@testable import Go

struct GoStepExecutorTests {
    private func object(_ line: String?) -> [String: Any]? {
        line.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
    }

    @Test func eachStepKindBecomesTheMatchingHarnessRequest() {
        let menu = GoWalkthroughStep(instruction: "Click File > New Folder.", app: "any.app", windowToken: "w", control: nil,
                                     menu: GoMenuTarget(id: "m1", path: ["File", "New Folder"]), expected: nil)
        #expect(object(GoStepExecutor.requestLine(for: menu))?["verb"] as? String == "menu")
        #expect(object(GoStepExecutor.requestLine(for: menu))?["path"] as? [String] == ["File", "New Folder"])
        #expect(object(GoStepExecutor.requestLine(for: menu))?["expectApp"] as? String == "any.app")

        let button = GoWalkthroughStep(instruction: "Click Share.", app: "any.app", windowToken: "w",
                                       control: GoControl(id: "c0", role: "AXButton", name: "Share", radioSelection: nil),
                                       menu: nil, expected: nil)
        #expect(object(GoStepExecutor.requestLine(for: button))?["verb"] as? String == "press")
        #expect(object(GoStepExecutor.requestLine(for: button))?["title"] as? String == "Share")

        let row = GoWalkthroughStep(instruction: "Choose Desktop.", app: "any.app", windowToken: "w",
                                    control: GoControl(id: "c1", role: "AXRow", name: "Desktop", radioSelection: nil),
                                    menu: nil, expected: nil)
        #expect(object(GoStepExecutor.requestLine(for: row))?["verb"] as? String == "select")

        let focused = GoTextField(id: "t0", role: "AXTextField", label: "", focused: true, x: 0, y: 0, w: 10, h: 10)
        let typing = GoWalkthroughStep(instruction: "Type test.", app: "any.app", windowToken: "w", control: nil, menu: nil,
                                       expected: nil, field: focused, typeText: "test")
        #expect(object(GoStepExecutor.requestLine(for: typing))?["verb"] as? String == "type")
        #expect(object(GoStepExecutor.requestLine(for: typing))?["target"] as? String == "focused")
        #expect(object(GoStepExecutor.requestLine(for: typing))?["text"] as? String == "test")

        // An unnamed, unfocused field has nothing safe to aim at.
        let unnamed = GoWalkthroughStep(instruction: "Type test.", app: "any.app", windowToken: "w", control: nil, menu: nil,
                                        expected: nil, field: GoTextField(id: "t1", role: "AXTextField", label: "", focused: false,
                                                                          x: 0, y: 0, w: 10, h: 10), typeText: "test")
        #expect(GoStepExecutor.requestLine(for: unnamed) == nil)
    }

    @Test func safetyAndConsentRefusalsAreFinalWhileMissesAreRetried() {
        #expect(GoStepExecutor.outcome(from: ["ok": true]) == .done)
        for code in ["kernelRefused", "killSwitch", "confirmationDenied", "confirmationExpired", "confirmationStale", "guidanceOnly"] {
            if case .blocked = GoStepExecutor.outcome(from: ["ok": false, "error": code]) {} else { Issue.record("\(code) not blocked") }
        }
        for code in ["notFound", "ambiguous", "notVerified", "frontmostChanged"] {
            if case .retryable = GoStepExecutor.outcome(from: ["ok": false, "error": code]) {} else { Issue.record("\(code) not retryable") }
        }
    }

    @Test func takeoverPhrasesAreRecognisedAndNegationsAreNot() {
        #expect(GoGuidanceIntent.parse("Do it for me") == .doForMe)
        #expect(GoGuidanceIntent.parse("Can you just do the rest?") == .doForMe)
        #expect(GoGuidanceIntent.parse("Can you create a folder called test for me?") == .doTaskForMe("create a folder called test"))
        #expect(GoGuidanceIntent.parse("Please do it for me") == .doForMe)
        #expect(GoGuidanceIntent.parse("Don't do it for me, show me how") != .doForMe)
        #expect(GoGuidanceIntent.parse("Show me how to create a folder") == .newTask("create a folder"))
    }
}

@MainActor
struct GoAutopilotTests {
    /// A fake app: "Open" is always there; "Continue" appears once Go presses Open.
    private final class App: @unchecked Sendable {
        private let lock = NSLock()
        private var opened = false
        private(set) var actions: [String] = []
        func answer(_ line: String) -> String {
            lock.lock(); defer { lock.unlock() }
            if line.contains("\"menus\"") { return #"{"ok":true,"items":[]}"# }
            if line.contains("\"press\"") { actions.append(line); opened = true; return #"{"ok":true}"# }
            let names = opened ? ["Open", "Continue"] : ["Open"]
            let object: [String: Any] = ["ok": true, "bundleIdentifier": "org.test.any-app",
                "window": ["name": "Workspace", "token": "one"], "walkStopReasons": [],
                "focusChangedDuringWalk": false, "incompleteReads": false,
                "elements": names.map { ["role": "AXButton", "name": $0, "nameIsPlausibleLabel": true] as [String: Any] }]
            return String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
        }
    }

    private func goals() -> GoGoalStore {
        let store = GoGoalStore(url: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("goal.json"))
        _ = store.apply(GoGoalRequest(operation: .set, expectedRevision: 0, sourceQuote: "Open it for me", task: "open it"),
                        heard: "Open it for me")
        return store
    }

    @Test func goActsVerifiesAndPlansUntilDone() async {
        let app = App()
        var plans = 0
        let coordinator = GoWalkthroughCoordinator(goals: goals(), answer: { app.answer($0) }, planner: { context in
            plans += 1
            if context.verifiedSteps.isEmpty {
                return GoStepProposal(kind: .step, instruction: "Click Open.", targetID: "c0", expected: nil)
            }
            #expect(context.observation.controls.contains { $0.name == "Continue" })
            return GoStepProposal(kind: .done, instruction: "All done.", targetID: nil, expected: nil)
        }, frontmostApp: { "org.test.any-app" }, logTransitions: false)
        await coordinator.runForMe { step in
            await GoStepExecutor.perform(step, answer: { app.answer($0) }, onConfirmationRequired: {})
        }
        #expect(app.actions.count == 1)
        #expect(plans == 2)
        #expect(coordinator.state.phase == .done)
        #expect(coordinator.state.message == "All done.")
        #expect(!coordinator.autopilot)
    }

    @Test func everyActionWaitsForThePointerToLandFirst() async {
        let app = App()
        var events: [String] = []
        let coordinator = GoWalkthroughCoordinator(goals: goals(), answer: { app.answer($0) }, planner: { context in
            context.verifiedSteps.count < 2
                ? GoStepProposal(kind: .step, instruction: "Click Open.", targetID: context.verifiedSteps.isEmpty ? "c0" : "c1", expected: nil)
                : GoStepProposal(kind: .done, instruction: "All done.", targetID: nil, expected: nil)
        }, frontmostApp: { "org.test.any-app" }, logTransitions: false)
        await coordinator.runForMe(perform: { step in
            events.append("act")
            return await GoStepExecutor.perform(step, answer: { app.answer($0) }, onConfirmationRequired: {})
        }, pointerSettled: { events.append("landed") })
        #expect(events == ["landed", "act", "landed", "act"])
        #expect(coordinator.state.phase == .done)
    }

    @Test func takingOverAShownStepActsOnItWhenTheScreenIsUnchanged() async {
        let app = App()
        var plans = 0
        let coordinator = GoWalkthroughCoordinator(goals: goals(), answer: { app.answer($0) }, planner: { context in
            plans += 1
            return context.verifiedSteps.isEmpty
                ? GoStepProposal(kind: .step, instruction: "Click Open.", targetID: "c0", expected: nil)
                : GoStepProposal(kind: .done, instruction: "All done.", targetID: nil, expected: nil)
        }, frontmostApp: { "org.test.any-app" }, logTransitions: false)
        _ = await coordinator.start()                 // Go shows the step to the owner
        await coordinator.runForMe { step in           // "do it for me", nothing touched
            await GoStepExecutor.perform(step, answer: { app.answer($0) }, onConfirmationRequired: {})
        }
        #expect(plans == 2)                            // the shown step, then the plan after acting
        #expect(app.actions.count == 1)
        #expect(coordinator.state.phase == .done)
    }

    @Test func takingOverAfterTheScreenChangedLooksAgainFirst() async {
        let app = App()
        var plans = 0
        let coordinator = GoWalkthroughCoordinator(goals: goals(), answer: { app.answer($0) }, planner: { context in
            plans += 1
            if plans == 1 { return GoStepProposal(kind: .step, instruction: "Click Open.", targetID: "c0", expected: nil) }
            return GoStepProposal(kind: .done, instruction: "All done.", targetID: nil, expected: nil)
        }, frontmostApp: { "org.test.any-app" }, logTransitions: false)
        _ = await coordinator.start()
        _ = app.answer(#"{"verb":"press","title":"Open"}"#)   // the owner already did it
        var performed = 0
        await coordinator.runForMe { _ in performed += 1; return .done }
        #expect(plans == 2)                            // looked again instead of clicking twice
        #expect(performed == 0)
    }

    @Test func anActionThatNeverTakesEffectIsHandedOverNotLooped() async {
        let app = App()
        var attempts = 0
        let coordinator = GoWalkthroughCoordinator(goals: goals(), answer: { app.answer($0) }, planner: { context in
            var again = GoStepProposal(kind: .step, instruction: "Click Open.", targetID: "c0", expected: nil)
            again.lastStep = context.verifiedSteps.isEmpty ? nil : "notYet"
            return again
        }, frontmostApp: { "org.test.any-app" }, logTransitions: false)
        // Each press changes the screen (so it isn't "nothing changed"), but the
        // planner keeps seeing the step not take effect.
        await coordinator.runForMe { step in
            attempts += 1
            return await GoStepExecutor.perform(step, answer: { app.answer($0) }, onConfirmationRequired: {})
        }
        #expect(attempts == 2)
        #expect(!coordinator.autopilot)
        #expect(coordinator.state.phase == .waiting)
        #expect(coordinator.state.message.hasPrefix("I tried that, but it didn't take."))
    }

    @Test func whatThePlannerNotesOnOneScreenReachesTheNextPlan() async {
        let app = App()
        var seenNotes: [[String]] = []
        let coordinator = GoWalkthroughCoordinator(goals: goals(), answer: { app.answer($0) }, planner: { context in
            seenNotes.append(context.notes)
            guard context.verifiedSteps.isEmpty else {
                return GoStepProposal(kind: .done, instruction: "All done.", targetID: nil, expected: nil)
            }
            var step = GoStepProposal(kind: .step, instruction: "Click Open.", targetID: "c0", expected: nil)
            step.note = "Targets sheet: A=Region, B=Target, rows 2-6"
            return step
        }, frontmostApp: { "org.test.any-app" }, logTransitions: false)
        await coordinator.runForMe { step in
            await GoStepExecutor.perform(step, answer: { app.answer($0) }, onConfirmationRequired: {})
        }
        #expect(seenNotes == [[], ["Targets sheet: A=Region, B=Target, rows 2-6"]])
        // A new task starts with a clean page: its first plan sees no old notes.
        _ = await coordinator.start()
        #expect(seenNotes.last == [])
    }

    @Test func theChecklistIsKeptUntilThePlannerRevisesIt() async {
        let app = App()
        var seen: [[String]] = []
        let coordinator = GoWalkthroughCoordinator(goals: goals(), answer: { app.answer($0) }, planner: { context in
            seen.append(context.checklist)
            switch context.verifiedSteps.count {
            case 0:
                var step = GoStepProposal(kind: .step, instruction: "Click Open.", targetID: "c0", expected: nil)
                step.checklist = ["open the file", "need: which column holds sales", "  "]
                return step
            case 1:
                return GoStepProposal(kind: .step, instruction: "Click Continue.", targetID: "c1", expected: nil) // unchanged
            default:
                return GoStepProposal(kind: .done, instruction: "All done.", targetID: nil, expected: nil)
            }
        }, frontmostApp: { "org.test.any-app" }, logTransitions: false)
        await coordinator.runForMe { step in
            await GoStepExecutor.perform(step, answer: { app.answer($0) }, onConfirmationRequired: {})
        }
        // Sent back on every later plan, blank lines dropped; kept while the planner says nothing new.
        #expect(seen == [[], ["open the file", "need: which column holds sales"], ["open the file", "need: which column holds sales"]])
        _ = await coordinator.start()
        #expect(seen.last == [])      // a new task starts without it
    }

    @Test func aChecklistIsShortAndTidy() {
        let long = String(repeating: "y", count: 200)
        let kept = GoWalkthroughCoordinator.cleanedChecklist([" a ", "", long, "b", "c", "d", "e", "f", "g"])
        #expect(kept.count == 6)
        #expect(kept.first == "a")
        #expect(kept[1].count == 140)
    }

    @Test func aBlindNotYetIsCheckedAgainstTheScreenshot() async throws {
        let app = App()
        var shownScreenshot: [Bool] = []
        let coordinator = GoWalkthroughCoordinator(goals: goals(), answer: { app.answer($0) }, planner: { context in
            shownScreenshot.append(context.screenshotJPEG != nil)
            if context.verifiedSteps.isEmpty { return GoStepProposal(kind: .step, instruction: "Click Open.", targetID: "c0", expected: nil) }
            // Without the screen, the plan thinks the click failed and goes another way;
            // with it, the plan sees the click worked and carries on.
            var next = GoStepProposal(kind: .step, instruction: context.screenshotJPEG == nil ? "Use the menu instead." : "Click Continue.",
                                      targetID: context.screenshotJPEG == nil ? "c0" : "c1", expected: nil)
            next.lastStep = context.screenshotJPEG == nil ? "notYet" : "worked"
            return next
        }, capture: { ("/9j/", GoFrame(CGRect(x: 0, y: 0, width: 100, height: 100))) },
           frontmostApp: { "org.test.any-app" }, logTransitions: false)
        _ = await coordinator.start()
        let step = try #require(coordinator.state.step)
        _ = app.answer(#"{"verb":"press","title":"Open"}"#)      // the owner's click opens "Continue"
        await coordinator.targetClicked(step)
        #expect(coordinator.state.step?.control?.name == "Continue")
        #expect(coordinator.state.message.hasPrefix("Nice."))
        #expect(shownScreenshot.contains(true))
    }

    @Test func aMadeUpTargetIsCheckedAgainOnTheScreenBeforeAskingTheOwner() async {
        let app = App()
        var plans = 0
        let coordinator = GoWalkthroughCoordinator(goals: goals(), answer: { app.answer($0) }, planner: { context in
            plans += 1
            // The first plan invents an ID; the second look, with the screenshot, names a real one.
            return GoStepProposal(kind: .step, instruction: "Click Open.", targetID: plans == 1 ? "c99" : "c0", expected: nil)
        }, capture: { ("/9j/", GoFrame(CGRect(x: 0, y: 0, width: 100, height: 100))) },
           frontmostApp: { "org.test.any-app" }, logTransitions: false)
        _ = await coordinator.start()
        #expect(plans == 2)
        #expect(coordinator.state.phase == .waiting)
        #expect(coordinator.state.step?.control?.name == "Open")

        // Invented every time: the owner gets a plain question, never jargon.
        let stubborn = GoWalkthroughCoordinator(goals: goals(), answer: { app.answer($0) }, planner: { _ in
            GoStepProposal(kind: .step, instruction: "Click it.", targetID: "c99", expected: nil)
        }, capture: { ("/9j/", GoFrame(CGRect(x: 0, y: 0, width: 100, height: 100))) },
           frontmostApp: { "org.test.any-app" }, logTransitions: false)
        _ = await stubborn.start()
        #expect(stubborn.state.phase == .needsInput)
        #expect(stubborn.state.message == "I can't find that on screen right now. What's it called, or what does it look like?")
    }

    @Test func afterTheOwnerDoesAHandedBackStepGoCarriesOnByItself() async throws {
        let app = App()
        var resumed = 0
        let coordinator = GoWalkthroughCoordinator(goals: goals(), answer: { app.answer($0) }, planner: { context in
            context.verifiedSteps.isEmpty
                ? GoStepProposal(kind: .step, instruction: "Click Open.", targetID: "c0", expected: nil)
                : GoStepProposal(kind: .step, instruction: "Click Continue.", targetID: "c1", expected: nil)
        }, frontmostApp: { "org.test.any-app" }, logTransitions: false)
        coordinator.onResumeAutopilot = { resumed += 1 }
        await coordinator.runForMe { _ in .retryable("it didn't work") }
        #expect(coordinator.state.message.contains("I'll carry on after."))
        let handed = try #require(coordinator.state.step)
        _ = app.answer(#"{"verb":"press","title":"Open"}"#)   // the owner does it
        await coordinator.targetClicked(handed)
        #expect(resumed == 1)
        #expect(coordinator.state.step?.control?.name == "Continue")
        #expect(coordinator.pausedForQuestion)                  // acts on that fresh step, no second plan
    }

    @Test func whenTheOwnerGoesAnotherWayGoPlansFromThereWithoutCorrecting() async {
        let app = App()
        var plans = 0
        let coordinator = GoWalkthroughCoordinator(goals: goals(), answer: { app.answer($0) }, planner: { _ in
            plans += 1
            return plans == 1
                ? GoStepProposal(kind: .step, instruction: "Click Open.", targetID: "c0", expected: nil)
                : GoStepProposal(kind: .step, instruction: "Now click Continue.", targetID: "c1", expected: nil)
        }, frontmostApp: { "org.test.any-app" }, logTransitions: false)
        _ = await coordinator.start()
        _ = app.answer(#"{"verb":"press","title":"Open"}"#)   // the owner's own click changed the app
        await coordinator.followOwnersWay()
        #expect(plans == 2)
        #expect(coordinator.state.message == "Now click Continue.")        // no "Not quite"
    }

    @Test func aNoToGosQuestionEndsTheRunQuietly() async {
        let app = App()
        var plans = 0
        let coordinator = GoWalkthroughCoordinator(goals: goals(), answer: { app.answer($0) }, planner: { _ in
            plans += 1
            return GoStepProposal(kind: .step, instruction: "Click Open.", targetID: "c0", expected: nil)
        }, frontmostApp: { "org.test.any-app" }, logTransitions: false)
        await coordinator.runForMe { _ in .declined }            // the card wasn't approved
        #expect(plans == 1)                                     // no replanning around a no
        #expect(coordinator.state.phase == .done)
        #expect(coordinator.state.message == "Okay, I've left it as it is.")
        #expect(!coordinator.autopilot)
    }

    @Test func anAppThatStopsAnsweringDoesNotFreezeGo() async {
        // Every read hangs, like an app stuck half-way through opening a pop-up.
        let coordinator = GoWalkthroughCoordinator(goals: goals(), answer: { _ in usleep(3_000_000); return "{}" },
                                                   planner: { _ in GoStepProposal(kind: .done, instruction: "Done.", targetID: nil, expected: nil) },
                                                   frontmostApp: { "org.test.any-app" }, logTransitions: false)
        coordinator.readTimeLimit = .milliseconds(200)
        let started = ContinuousClock.now
        _ = await coordinator.start()
        #expect(ContinuousClock.now - started < .seconds(2.9))       // gave up well before the stuck reads ended
        #expect(coordinator.state.phase == .needsInput)
        #expect(coordinator.state.message.hasPrefix("That app isn't responding to me right now."))
    }

    @Test func controlsThatOpenSomethingAreKnown() {
        func step(_ role: String) -> GoWalkthroughStep {
            GoWalkthroughStep(instruction: "Click it.", app: "a", windowToken: "w",
                              control: GoControl(id: "c0", role: role, name: "Table", radioSelection: nil), menu: nil, expected: nil)
        }
        #expect(GoWalkthroughCoordinator.opensSomething(step("AXMenuButton")))
        #expect(GoWalkthroughCoordinator.opensSomething(step("AXPopUpButton")))
        #expect(!GoWalkthroughCoordinator.opensSomething(step("AXButton")))
        let menuTitle = GoWalkthroughStep(instruction: "Open the Edit menu.", app: "a", windowToken: "w", control: nil,
                                          menu: GoMenuTarget(id: "m0", path: ["Edit"]), expected: nil)
        #expect(GoWalkthroughCoordinator.opensSomething(menuTitle))
    }

    @Test func notesKeepOnlyNewLinesAndTheLatestTen() {
        var notes: [String] = []
        notes = GoWalkthroughCoordinator.addingNote("  Sheet2 holds targets ", to: notes)
        notes = GoWalkthroughCoordinator.addingNote("sheet2 holds targets", to: notes)   // a repeat
        notes = GoWalkthroughCoordinator.addingNote(nil, to: notes)
        notes = GoWalkthroughCoordinator.addingNote("   ", to: notes)
        #expect(notes == ["Sheet2 holds targets"])
        for index in 0..<12 { notes = GoWalkthroughCoordinator.addingNote("note \(index)", to: notes) }
        #expect(notes.count == 10)
        #expect(notes.last == "note 11")
        #expect(GoWalkthroughCoordinator.addingNote(String(repeating: "x", count: 400), to: []).first?.count == 280)
    }

    @Test func aFailedStepIsRetriedOnceThenHandedBack() async {
        let app = App()
        var attempts = 0
        let coordinator = GoWalkthroughCoordinator(goals: goals(), answer: { app.answer($0) }, planner: { _ in
            GoStepProposal(kind: .step, instruction: "Click Open.", targetID: "c0", expected: nil)
        }, frontmostApp: { "org.test.any-app" }, logTransitions: false)
        await coordinator.runForMe { _ in attempts += 1; return .retryable("I couldn't find that control") }
        #expect(attempts == 2)
        #expect(coordinator.state.phase == .waiting)
        #expect(coordinator.state.message.hasPrefix("I couldn't do this one"))
        #expect(!coordinator.autopilot)
    }

    @Test func aSafetyRefusalStopsImmediately() async {
        let app = App()
        var attempts = 0
        let coordinator = GoWalkthroughCoordinator(goals: goals(), answer: { app.answer($0) }, planner: { _ in
            GoStepProposal(kind: .step, instruction: "Click Open.", targetID: "c0", expected: nil)
        }, frontmostApp: { "org.test.any-app" }, logTransitions: false)
        await coordinator.runForMe { _ in attempts += 1; return .blocked("my safety check won't let me do that one") }
        #expect(attempts == 1)
        #expect(coordinator.state.message.contains("safety check"))
    }
}

struct GoPressReturnTests {
    @Test func returnIsAddedToTheInstructionOnlyWhenThePlannerAsks() {
        var observation = GoObservation(app: "any.app", windowToken: "w", windowName: "W", complete: true, controls: [])
        observation.fields = [GoTextField(id: "t0", role: "AXTextField", label: "", focused: true, x: 0, y: 0, w: 10, h: 10)]
        var state = GoWalkthroughState()
        state.accept(GoStepProposal(kind: .step, instruction: "Type \"test\" as the name.", targetID: "t0", expected: nil,
                                    typeText: "test", pressReturn: true), from: observation)
        #expect(state.step?.pressReturn == true)
        #expect(state.message.hasSuffix("Then press Return."))
        state.accept(GoStepProposal(kind: .step, instruction: "Type \"hello\" in the message box.", targetID: "t0", expected: nil,
                                    typeText: "hello", pressReturn: false), from: observation)
        #expect(state.step?.pressReturn == false)
        #expect(!state.message.contains("Return"))
    }
}

struct GoOpenAndLaunchTests {
    private var finder: GoObservation {
        GoObservation(app: "any.files", windowToken: "w", windowName: "Pictures", complete: true,
                      controls: [GoControl(id: "c0", role: "AXTextField", name: "FT.jpg", radioSelection: nil)])
    }

    @Test func filesAndLabelsAreListedButEditableFieldsAndLongTextAreNot() {
        let object: [String: Any] = ["ok": true, "bundleIdentifier": "any.app", "window": ["name": "W", "token": "1"],
            "walkStopReasons": [], "focusChangedDuringWalk": false, "incompleteReads": false,
            "elements": [["role": "AXTextField", "name": "FT.jpg", "nameIsPlausibleLabel": true, "actions": ["AXOpen"]],
                         ["role": "AXTextField", "name": "what I typed", "nameIsPlausibleLabel": true, "actions": ["AXConfirm"]],
                         ["role": "AXStaticText", "name": "Downloads", "nameIsPlausibleLabel": true, "actions": ["AXPress"]],
                         ["role": "AXStaticText", "name": String(repeating: "long paragraph ", count: 6), "nameIsPlausibleLabel": true]]]
        #expect(GoObservation.decode(object)?.controls.map(\.name) == ["FT.jpg", "Downloads"])
    }

    @Test func anOpenStepUsesTheOpenVerbAndIsNotFinishedByTheFirstClick() {
        var state = GoWalkthroughState()
        state.accept(GoStepProposal(kind: .step, instruction: "Double-click FT.jpg.", targetID: "c0", expected: nil, open: true), from: finder)
        guard let step = state.step else { Issue.record("no step"); return }
        #expect(step.opens)
        #expect(!GoGuidePresenter.completesOnClick(step))
        let line = GoStepExecutor.requestLine(for: step)
        #expect(line?.contains("\"open\"") == true)
        // Opening a folder in the same window changes its title: that completes the step.
        let opened = GoObservation(app: "any.files", windowToken: "w", windowName: "Holiday", complete: true, controls: [])
        _ = state.observe(opened, now: 0)
        let done = state.observe(opened, now: 0.3)
        #expect(done)
        // And it is never treated as going off track.
        var other = GoWalkthroughState()
        other.accept(GoStepProposal(kind: .step, instruction: "Double-click FT.jpg.", targetID: "c0", expected: nil, open: true), from: finder)
        _ = other.noteOffTrack(opened, now: 0)
        let offTrack = other.noteOffTrack(opened, now: 1)
        #expect(!offTrack)
    }

    @Test func aLaunchStepNamesTheAppAndUsesTheLaunchVerb() {
        var state = GoWalkthroughState()
        state.accept(GoStepProposal(kind: .launch, instruction: "Open Calendar.", targetID: nil, expected: nil, app: "Calendar"), from: finder)
        #expect(state.phase == .waiting)
        #expect(state.step?.launchApp == "Calendar")
        if let step = state.step {
            #expect(!GoGuidePresenter.completesOnClick(step))
            #expect(GoStepExecutor.requestLine(for: step)?.contains("\"launch\"") == true)
        }
        state.accept(GoStepProposal(kind: .launch, instruction: "Open it.", targetID: nil, expected: nil, app: " "), from: finder)
        #expect(state.phase == .needsInput)
    }
}

@MainActor
struct GoOwnerAnswerTests {
    private final class Dialog: @unchecked Sendable {
        func answer(_ line: String) -> String {
            if line.contains("\"menus\"") { return #"{"ok":true,"items":[]}"# }
            let object: [String: Any] = ["ok": true, "bundleIdentifier": "any.app", "window": ["name": "New folder", "token": "w"],
                "walkStopReasons": [], "focusChangedDuringWalk": false, "incompleteReads": false,
                "elements": ["Create", "Cancel"].map { ["role": "AXButton", "name": $0, "nameIsPlausibleLabel": true] as [String: Any] }]
            return String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
        }
    }

    @Test func anAnswerToGosQuestionRefinesTheGoalAndKeepsTheWalkthrough() async {
        let store = GoGoalStore(url: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("goal.json"))
        _ = store.apply(GoGoalRequest(operation: .set, expectedRevision: 0, sourceQuote: "Create a new folder", task: "create a folder"),
                        heard: "Create a new folder")
        let app = Dialog()
        var seen: [(last: String, steps: Int)] = []
        let coordinator = GoWalkthroughCoordinator(goals: store, answer: { app.answer($0) }, planner: { context in
            seen.append((context.goal.lastInstruction, context.verifiedSteps.count))
            if seen.count == 1 { return GoStepProposal(kind: .step, instruction: "Click Create.", targetID: "c0", expected: nil) }
            if context.goal.lastInstruction == "Create a new folder" {
                return GoStepProposal(kind: .ask, instruction: "What should it be called? Or I can keep \"Untitled folder\".", targetID: nil, expected: nil)
            }
            return GoStepProposal(kind: .done, instruction: "Done.", targetID: nil, expected: nil)
        }, capture: { nil }, frontmostApp: { "any.app" }, logTransitions: false)
        _ = await coordinator.start()
        _ = await coordinator.proceed()          // "I did it" → step recorded, planner asks for a name
        #expect(coordinator.state.phase == .needsInput)
        _ = store.apply(GoGoalRequest(operation: .update, sourceQuote: "Call it Receipts"), heard: "Call it Receipts",
                        boundRevision: store.state.revision)
        _ = await coordinator.proceed(ownerAnswered: true)
        #expect(seen.last?.last == "Call it Receipts")
        #expect(seen.last?.steps == 1)           // the earlier step is kept, not restarted
        #expect(coordinator.state.phase == .done)
    }
}

@MainActor
struct GoShortTermMemoryTests {
    private final class Tabs: @unchecked Sendable {
        func answer(_ line: String) -> String {
            if line.contains("\"menus\"") { return #"{"ok":true,"items":[]}"# }
            let object: [String: Any] = ["ok": true, "bundleIdentifier": "any.browser", "window": ["name": "Inbox", "token": "w"],
                "walkStopReasons": [], "focusChangedDuringWalk": false, "incompleteReads": false,
                "elements": ["Inbox", "FT"].map { ["role": "AXTab", "name": $0, "nameIsPlausibleLabel": true] as [String: Any] }]
            return String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
        }
    }

    @Test func aFollowUpSeesWhatGoJustPointedAtAndTheEarlierRequest() async {
        let store = GoGoalStore(url: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("goal.json"))
        _ = store.apply(GoGoalRequest(operation: .set, expectedRevision: 0, sourceQuote: "Where is the FT tab", task: "find the FT tab"),
                        heard: "Where is the FT tab")
        let app = Tabs()
        var recentSeen: [[String]] = []
        let coordinator = GoWalkthroughCoordinator(goals: store, answer: { app.answer($0) }, planner: { context in
            recentSeen.append(context.recent)
            return GoStepProposal(kind: .point, instruction: "Here's the FT tab.", targetID: "c1", expected: nil)
        }, capture: { nil }, frontmostApp: { "any.browser" }, logTransitions: false)
        _ = await coordinator.start()
        // "Can you open it?" replaces the goal; the session remembers the earlier request first.
        coordinator.remember("Earlier request: \u{201C}Where is the FT tab\u{201D}")
        _ = store.apply(GoGoalRequest(operation: .set, expectedRevision: store.state.revision, sourceQuote: "Can you open it", task: "open it"),
                        heard: "Can you open it")
        _ = await coordinator.start()
        let last = recentSeen.last ?? []
        #expect(last.contains("Go pointed at tab 'FT'"))
        #expect(last.contains("Earlier request: \u{201C}Where is the FT tab\u{201D}"))
    }
}
