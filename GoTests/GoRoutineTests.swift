import CoreGraphics
import Foundation
import Testing
@testable import Go

struct GoRoutineIntentTests {
    private let names = ["Morning setup", "Export Reel"]

    @Test func saveTakesAnyNameAndKnowsWhenTheWordsSayRoutine() {
        #expect(GoRoutineIntent.parse("Save this as Morning setup.", names: []) == .save(name: "Morning setup", explicit: false))
        #expect(GoRoutineIntent.parse("remember that as weekly report please", names: []) == .save(name: "weekly report", explicit: false))
        #expect(GoRoutineIntent.parse("Save this routine as Invoice run", names: []) == .save(name: "Invoice run", explicit: true))
        #expect(GoRoutineIntent.parse("Save these steps as Backup", names: []) == .save(name: "Backup", explicit: true))
        #expect(GoRoutineIntent.parse("save this as a routine called Tidy desktop", names: []) == .save(name: "Tidy desktop", explicit: true))
        // A file format is a task, not a routine name.
        #expect(GoRoutineIntent.parse("Save this as PDF", names: []) == nil)
        #expect(GoRoutineIntent.parse("save it as a PNG", names: []) == nil)
    }

    @Test func runWalkAndDeleteOnlyMatchRoutinesThatExist() {
        #expect(GoRoutineIntent.parse("Run morning setup", names: names) == .run(name: "Morning setup"))
        #expect(GoRoutineIntent.parse("Do my Export Reel routine.", names: names) == .run(name: "Export Reel"))
        #expect(GoRoutineIntent.parse("Go, export reel", names: names) == .run(name: "Export Reel"))
        #expect(GoRoutineIntent.parse("Walk me through morning setup", names: names) == .walk(name: "Morning setup"))
        #expect(GoRoutineIntent.parse("Delete the export reel routine", names: names) == .delete(name: "Export Reel"))
        #expect(GoRoutineIntent.parse("What routines do I have?", names: names) == .list)
        // Anywhere in the sentence, with polite words around the name.
        #expect(GoRoutineIntent.parse("Can you run morning setup for me?", names: names) == .run(name: "Morning setup"))
        #expect(GoRoutineIntent.parse("Okay, run my Morning Setup routine please.", names: names) == .run(name: "Morning setup"))
        #expect(GoRoutineIntent.parse("Hey Go, walk me through export reel", names: names) == .walk(name: "Export Reel"))
        #expect(GoRoutineIntent.parse("Could you do export reel again", names: names) == .run(name: "Export Reel"))
        #expect(GoRoutineIntent.parse("I want to run a marathon", names: names) == nil)
        // Names as speech-to-text writes them.
        let youtube = ["YouTube routine"]
        #expect(GoRoutineIntent.parse("Run the You Tube routine.", names: youtube) == .run(name: "YouTube routine"))
        #expect(GoRoutineIntent.parse("run youtub routine", names: youtube) == .run(name: "YouTube routine"))
        #expect(GoRoutineIntent.parse("Run my YouTube routine for me", names: youtube) == .run(name: "YouTube routine"))
        #expect(GoRoutineIntent.parse("Run the change the brightness routine", names: ["change brightness"]) == .run(name: "change brightness"))
        // "<name> routine" still runs it when the words before it were misheard.
        #expect(GoRoutineIntent.parse("One man Messiah routine", names: ["my Messiah routine"]) == .run(name: "my Messiah routine"))
        // "Run it" right after saving or using a routine means that routine.
        #expect(GoRoutineIntent.parse("Now run it", names: names, recent: "Export Reel") == .run(name: "Export Reel"))
        #expect(GoRoutineIntent.parse("Can you do that routine for me?", names: names, recent: "Export Reel") == .run(name: "Export Reel"))
        #expect(GoRoutineIntent.parse("Walk me through it", names: names, recent: "Morning setup") == .walk(name: "Morning setup"))
        #expect(GoRoutineIntent.parse("Now run it", names: names) == nil)
        #expect(GoRoutineIntent.parse("Do it for me", names: names, recent: "Export Reel") == nil)
        // Asked for a routine that doesn't exist: said so, not silently guided.
        #expect(GoRoutineIntent.parse("Run the Spotify routine", names: youtube) == .unknown(name: "spotify"))
        // Near-misses never match when two names are equally close.
        #expect(GoRoutine.match("setup b", among: ["Setup A", "Setup C"], fuzzy: true) == nil)
        // Ordinary requests pass through untouched.
        #expect(GoRoutineIntent.parse("Walk me through exporting a video", names: names) == nil)
        #expect(GoRoutineIntent.parse("Do it for me", names: names) == nil)
        #expect(GoRoutineIntent.parse("Run the tests", names: names) == nil)
    }
}

struct GoRoutineStepTests {
    private func field(_ label: String) -> GoTextField {
        GoTextField(id: "t0", role: "AXTextField", label: label, focused: false, x: 0, y: 0, w: 10, h: 10)
    }

    @Test func stepsAreSavedByWhatTheyTargetAndSecretsAreNeverKept() {
        let button = GoWalkthroughStep(instruction: "Click Share.", app: "any.app", windowToken: "w",
                                       control: GoControl(id: "c4", role: "AXButton", name: "Share", radioSelection: nil),
                                       menu: nil, expected: nil)
        #expect(GoRoutineStep(button).targetKey == "control:AXButton:Share")
        let named = GoWalkthroughStep(instruction: "Type the title.", app: "any.app", windowToken: "w", control: nil, menu: nil,
                                      expected: nil, field: field("Title"), typeText: "Weekly report")
        #expect(GoRoutineStep(named).typeText == "Weekly report")
        for label in ["Password", "Verification code", "Card number", "API key"] {
            let secret = GoWalkthroughStep(instruction: "Type it.", app: "any.app", windowToken: "w", control: nil, menu: nil,
                                           expected: nil, field: field(label), typeText: "hunter2")
            #expect(GoRoutineStep(secret).typeText == nil, "\(label)")
        }
        var icon = GoWalkthroughStep(instruction: "Click Control Center.", app: "any.app", windowToken: "w",
                                     control: nil, menu: nil, expected: nil)
        icon.screenRect = GoFrame(CGRect(x: 1, y: 1, width: 20, height: 20)); icon.outsideWindow = true; icon.outsideName = "Control Center"
        #expect(GoRoutineStep(icon).targetKey == "outside:Control Center")
        #expect(GoRoutineStep(icon).screenLabel == nil)
    }

    @Test func memoryRecordsWhatWasTypedButNotSecrets() {
        let typed = GoWalkthroughStep(instruction: "Type the command.", app: "any.app", windowToken: "w", control: nil, menu: nil,
                                      expected: nil, field: field("Command"), typeText: "touch notes.txt")
        #expect(typed.targetDescription == "typing \u{201C}touch notes.txt\u{201D} into the Command field")
        let secret = GoWalkthroughStep(instruction: "Type it.", app: "any.app", windowToken: "w", control: nil, menu: nil,
                                       expected: nil, field: field("Password"), typeText: "hunter2")
        #expect(!secret.targetDescription.contains("hunter2"))
    }

    @Test func aSavedStepIsFoundAgainOnTheCurrentScreenByName() {
        var observation = GoObservation(app: "any.app", windowToken: "new", windowName: "Other", complete: true,
                                        controls: [GoControl(id: "c9", role: "AXButton", name: "Share", radioSelection: nil)])
        observation.menus = [GoMenuTarget(id: "m3", path: ["File", "Export"])]
        observation.fields = [GoTextField(id: "t2", role: "AXTextField", label: "Title", focused: false, x: 0, y: 0, w: 10, h: 10)]
        observation.systemControls = [GoSystemControl(id: "s1", kind: "menuBarIcon", name: "Control Center",
                                                      frame: GoFrame(CGRect(x: 1, y: 1, width: 20, height: 20)))]
        var share = GoRoutineStep(instruction: "Click Share.", app: "any.app")
        share.controlRole = "AXButton"; share.controlName = "Share"
        #expect(GoRoutineReplay.proposal(for: share, in: observation)?.targetID == "c9")
        var export = GoRoutineStep(instruction: "Choose File > Export.", app: "any.app")
        export.menuPath = ["File", "Export"]
        #expect(GoRoutineReplay.proposal(for: export, in: observation)?.targetID == "m3")
        var title = GoRoutineStep(instruction: "Type the title.", app: "any.app")
        title.fieldRole = "AXTextField"; title.fieldLabel = "Title"; title.typeText = "Weekly report"
        #expect(GoRoutineReplay.proposal(for: title, in: observation)?.typeText == "Weekly report")
        var icon = GoRoutineStep(instruction: "Click Control Center.", app: "other.app")
        icon.outsideName = "Control Center"
        #expect(GoRoutineReplay.proposal(for: icon, in: observation)?.targetID == "s1")
        var open = GoRoutineStep(instruction: "Open Notes.", app: "any.app")
        open.launchApp = "Notes"
        #expect(GoRoutineReplay.proposal(for: open, in: observation)?.kind == .launch)
        // Another app's control, or one that isn't here, is left to the planner.
        var elsewhere = share; elsewhere = GoRoutineStep(instruction: "Click Share.", app: "other.app")
        elsewhere.controlRole = "AXButton"; elsewhere.controlName = "Share"
        #expect(GoRoutineReplay.proposal(for: elsewhere, in: observation) == nil)
        var missing = share; missing.controlName = "Publish"
        #expect(GoRoutineReplay.proposal(for: missing, in: observation) == nil)
        // A secret that wasn't saved is asked for, not guessed.
        var secret = title; secret.typeText = nil
        #expect(GoRoutineReplay.proposal(for: secret, in: observation) == nil)
    }
}

@MainActor
struct GoRoutineStoreTests {
    @Test func routinesSavedByAnOlderGoStillLoadAndSavingKeepsWorking() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("routines.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Written before keyboard steps existed: no "keys" or "keyboard", and one damaged entry.
        let old = #"[{"id":"E749B5BD-0036-44BF-9765-9C5C7ABD3499","name":"Old","goal":"g","created":812140434.4,"steps":[{"instruction":"Click it.","app":"any.app","reveal":false,"opens":false,"pressReturn":false,"final":false,"risk":{"level":"none"}}]},{"name":"Broken"}]"#
        try Data(old.utf8).write(to: url)
        let store = GoRoutineStore(url: url)
        #expect(store.routines.map(\.name) == ["Old"])
        #expect(store.save(name: "New", goal: "g", steps: [GoRoutineStep(instruction: "Click.", app: "any.app")]))
        // A file that isn't a list at all is kept as a backup, and saving still works.
        try Data("not json".utf8).write(to: url)
        let fresh = GoRoutineStore(url: url)
        #expect(fresh.routines.isEmpty)
        #expect(fresh.save(name: "After", goal: "g", steps: [GoRoutineStep(instruction: "Click.", app: "any.app")]))
        let backups = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
            .filter { $0.hasPrefix("routines-unreadable-") }
        #expect(backups.count == 1)
    }

    @Test func routinesAreSavedReplacedByNameAndDeletedPrivately() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("routines.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = GoRoutineStore(url: url)
        let step = GoRoutineStep(instruction: "Click Share.", app: "any.app")
        #expect(store.save(name: "Weekly report", goal: "send the weekly report", steps: [step]))
        #expect(store.save(name: "weekly REPORT", goal: "send it again", steps: [step, step]))
        #expect(store.routines.count == 1)
        #expect(GoRoutineStore(url: url).routine(named: "my weekly report routine")?.steps.count == 2)
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        #expect(!store.save(name: "Empty", goal: "x", steps: []))
        #expect(store.delete(named: "Weekly report"))
        #expect(GoRoutineStore(url: url).routines.isEmpty)
    }
}

@MainActor
struct GoRoutineReplayTests {
    /// A fake app: "Open" is always there; "Continue" appears once Open is pressed.
    private final class App: @unchecked Sendable {
        private let lock = NSLock()
        private var opened = false
        private(set) var pressed: [String] = []
        func answer(_ line: String) -> String {
            lock.lock(); defer { lock.unlock() }
            if line.contains("\"menus\"") { return #"{"ok":true,"items":[]}"# }
            if line.contains("\"press\"") {
                let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
                pressed.append(object?["title"] as? String ?? "?"); opened = true
                return #"{"ok":true}"#
            }
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
        _ = store.apply(GoGoalRequest(operation: .set, expectedRevision: 0, sourceQuote: "Run setup", task: "set things up"),
                        heard: "Run setup")
        return store
    }

    private func button(_ name: String) -> GoRoutineStep {
        var step = GoRoutineStep(instruction: "Click \(name).", app: "org.test.any-app")
        step.controlRole = "AXButton"; step.controlName = name
        return step
    }

    @Test func aRoutineOnTheSameScreenReplaysWithoutThePlanner() async {
        let app = App()
        var plans = 0
        let coordinator = GoWalkthroughCoordinator(goals: goals(), answer: { app.answer($0) }, planner: { _ in
            plans += 1
            return GoStepProposal(kind: .ask, instruction: "?", targetID: nil, expected: nil)
        }, frontmostApp: { "org.test.any-app" }, logTransitions: false)
        coordinator.useRoutine(GoRoutine(id: UUID(), name: "Setup", goal: "set things up",
                                         steps: [button("Open"), button("Continue")], created: Date()))
        await coordinator.runForMe { step in
            await GoStepExecutor.perform(step, answer: { app.answer($0) }, onConfirmationRequired: {})
        }
        #expect(app.pressed == ["Open", "Continue"])
        #expect(plans == 0)
        #expect(coordinator.state.phase == .done)
        #expect(coordinator.state.message == "That's Setup done.")
        #expect(coordinator.runningRoutineName == nil)
    }

    @Test func aPointerOnlyStepIsHandedToTheOwnerNotClicked() async {
        let app = App()
        var last = button("Continue"); last.final = true
        let coordinator = GoWalkthroughCoordinator(goals: goals(), answer: { app.answer($0) }, planner: { _ in
            GoStepProposal(kind: .ask, instruction: "?", targetID: nil, expected: nil)
        }, frontmostApp: { "org.test.any-app" }, logTransitions: false)
        coordinator.useRoutine(GoRoutine(id: UUID(), name: "Setup", goal: "set things up",
                                         steps: [button("Open"), last], created: Date()))
        await coordinator.runForMe { step in
            await GoStepExecutor.perform(step, answer: { app.answer($0) }, onConfirmationRequired: {})
        }
        #expect(app.pressed == ["Open"])
        #expect(coordinator.state.phase == .waiting)
        #expect(coordinator.state.message.hasPrefix("Over to you: "))
        #expect(!coordinator.autopilot)
    }

    @Test func aStepThatIsNotHereAsksThePlannerWithTheRecordedStep() async {
        let app = App()
        var hints: [String?] = []
        let coordinator = GoWalkthroughCoordinator(goals: goals(), answer: { app.answer($0) }, planner: { context in
            hints.append(context.routineHint)
            return GoStepProposal(kind: .ask, instruction: "Where is Publish?", targetID: nil, expected: nil)
        }, frontmostApp: { "org.test.any-app" }, logTransitions: false)
        coordinator.useRoutine(GoRoutine(id: UUID(), name: "Setup", goal: "set things up",
                                         steps: [button("Publish")], created: Date()))
        _ = await coordinator.start()
        #expect(hints.first??.contains("Setup") == true)
        #expect(hints.first??.contains("control: Publish") == true)
        #expect(coordinator.state.phase == .needsInput)
    }

    @Test func aClickWhileGoIsStillTalkingIsKeptAndCountsWhenTheTurnEnds() async throws {
        let app = App()
        let coordinator = GoWalkthroughCoordinator(goals: goals(), answer: { app.answer($0) }, planner: { context in
            context.verifiedSteps.isEmpty
                ? GoStepProposal(kind: .step, instruction: "Click Open.", targetID: "c0", expected: nil)
                : GoStepProposal(kind: .done, instruction: "All done.", targetID: nil, expected: nil)
        }, frontmostApp: { "org.test.any-app" }, logTransitions: false)
        _ = await coordinator.start()
        let step = try #require(coordinator.state.step)
        coordinator.suspend()                      // a voice turn is still running
        await coordinator.targetClicked(step)      // the owner clicks the pointed target
        #expect(coordinator.state.verifiedSteps.isEmpty)
        coordinator.resume()                       // the turn ends
        for _ in 0..<50 where coordinator.state.phase != .done { try await Task.sleep(for: .milliseconds(40)) }
        #expect(coordinator.state.verifiedSteps.count == 1)
        #expect(coordinator.state.phase == .done)
    }

    @Test func aFinishedWalkthroughIsWhatGetsSaved() async {
        let app = App()
        let coordinator = GoWalkthroughCoordinator(goals: goals(), answer: { app.answer($0) }, planner: { context in
            context.verifiedSteps.isEmpty
                ? GoStepProposal(kind: .step, instruction: "Click Open.", targetID: "c0", expected: nil)
                : GoStepProposal(kind: .done, instruction: "All done.", targetID: nil, expected: nil)
        }, frontmostApp: { "org.test.any-app" }, logTransitions: false)
        await coordinator.runForMe { step in
            await GoStepExecutor.perform(step, answer: { app.answer($0) }, onConfirmationRequired: {})
        }
        #expect(coordinator.stepsToSave?.steps.map { GoRoutineStep($0).targetKey } == ["control:AXButton:Open"])
        #expect(coordinator.stepsToSave?.goal == "set things up")
        #expect(coordinator.secondsSinceLastFinished != nil)
    }
}
