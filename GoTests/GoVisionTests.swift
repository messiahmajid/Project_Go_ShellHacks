import CoreGraphics
import Foundation
import Testing
@testable import Go

struct GoScreenTargetTests {
    private var observation: GoObservation {
        var observation = GoObservation(app: "any.editor", windowToken: "w", windowName: "Project", complete: true, controls: [])
        observation.screenFrame = GoFrame(CGRect(x: 0, y: 0, width: 1280, height: 800))
        return observation
    }

    @Test func aBoxOnTheScreenshotBecomesAScreenRectangle() {
        // Top-right icon: 0–1000 box [ymin, xmin, ymax, xmax] over a 1280×800 display (AppKit origin bottom-left).
        let rect = observation.screenRect(forBox: [42, 923, 90, 952])
        #expect(rect.map { abs($0.minX - 1181.44) < 0.5 && abs($0.maxY - 766.4) < 0.5 && abs($0.height - 38.4) < 0.5 } == true)
        #expect(observation.screenRect(forBox: [90, 923, 42, 952]) == nil)   // inverted
        #expect(observation.screenRect(forBox: [0, 0, 999, 999]) == nil)     // implausibly large
        #expect(observation.screenRect(forBox: [10, 10, 11, 11]) == nil)     // too small to be a control
        #expect(observation.screenRect(forBox: nil) == nil)
    }

    @Test func aWideRowInAWindowSizedPictureIsAControlNotTheWholeWindow() {
        // The picture is often just the app's window: a row of options spans most of its width.
        var window = GoObservation(app: "any.settings", windowToken: "w", windowName: "Displays", complete: true, controls: [])
        window.screenFrame = GoFrame(CGRect(x: 400, y: 200, width: 700, height: 600))
        #expect(window.screenRect(forBox: [300, 50, 380, 950]) != nil)       // a wide row of choices
        #expect(window.screenRect(forBox: [50, 400, 950, 520]) != nil)       // a tall panel
        #expect(window.screenRect(forBox: [0, 0, 1000, 1000]) == nil)        // the whole window
        #expect(window.screenRect(forBox: [100, 100, 900, 900]) == nil)      // most of it
    }

    @Test func aScreenStepPointsAtTheBoxAndFinishesOnAClick() {
        var state = GoWalkthroughState()
        state.accept(GoStepProposal(kind: .step, instruction: "Click the up-arrow Export icon.", targetID: "screen", expected: nil,
                                    box: [42, 923, 90, 952], label: "Export icon"), from: observation)
        #expect(state.phase == .waiting)
        #expect(state.step?.screenRect != nil)
        #expect(state.step?.screenLabel == "Export icon")
        if let step = state.step { #expect(GoGuidePresenter.completesOnClick(step)) }
        // Without a screenshot there is nothing to map the box onto.
        var blind = GoWalkthroughState()
        blind.accept(GoStepProposal(kind: .step, instruction: "Click it.", targetID: "screen", expected: nil, box: [42, 923, 90, 952]),
                     from: GoObservation(app: "any.editor", windowToken: "w", windowName: "P", complete: true, controls: []))
        #expect(blind.phase == .needsInput)
    }

    private var withMenuBar: GoObservation {
        var observation = self.observation
        // Three neighbouring menu-bar icons, 30 pt apart, and one Dock item.
        observation.systemControls = [
            GoSystemControl(id: "s0", kind: "menuBarIcon", name: "Wi-Fi", frame: GoFrame(CGRect(x: 1100, y: 776, width: 26, height: 24))),
            GoSystemControl(id: "s1", kind: "menuBarIcon", name: "Control Center", frame: GoFrame(CGRect(x: 1130, y: 776, width: 26, height: 24))),
            GoSystemControl(id: "s2", kind: "menuBarIcon", name: "Clock", frame: GoFrame(CGRect(x: 1160, y: 776, width: 110, height: 24))),
            GoSystemControl(id: "s3", kind: "dockItem", name: "Notes", frame: GoFrame(CGRect(x: 600, y: 0, width: 48, height: 48))),
        ]
        return observation
    }

    @Test func aListedOutsideControlIsTargetedWithItsExactFrame() {
        var state = GoWalkthroughState()
        state.accept(GoStepProposal(kind: .step, instruction: "Click Control Center in the menu bar.", targetID: "s1", expected: nil),
                     from: withMenuBar)
        #expect(state.phase == .waiting)
        #expect(state.step?.screenRect == GoFrame(CGRect(x: 1130, y: 776, width: 26, height: 24)))
        #expect(state.step?.outsideWindow == true)
        #expect(state.step?.screenLabel == "Control Center")
    }

    @Test func aBoxOneIconOffSnapsToTheIconItsLabelNames() {
        // The box's centre sits on the clock, but the label says Control Center.
        let offByOne = withMenuBar.screenRect(forBox: [0, 912, 30, 930]).map { CGRect(x: 1165, y: $0.minY, width: $0.width, height: $0.height) }!
        #expect(withMenuBar.systemControl(near: offByOne, label: "Control Center icon")?.id == "s1")
        // No name in the label: the icon under the centre.
        #expect(withMenuBar.systemControl(near: offByOne, label: "the icon")?.id == "s2")
        // Nowhere near a listed control: no snapping.
        #expect(withMenuBar.systemControl(near: CGRect(x: 300, y: 400, width: 30, height: 30), label: "Control Center") == nil)
    }

    @Test func aBoxOnADockItemItsLabelDoesNotNameIsOffTargetNotClicked() {
        // The box sits on the Notes Dock item, but the plan describes a control inside the app.
        let onNotes: [Double] = [945, 470, 995, 505]
        var state = GoWalkthroughState()
        state.accept(GoStepProposal(kind: .step, instruction: "Click Insert Chart.", targetID: "screen", expected: nil,
                                    box: onNotes, label: "Insert Chart"), from: withMenuBar)
        #expect(state.phase == .needsInput)
        #expect(state.step == nil)
        #expect(state.boxLandedOn?.id == "s3")
        // The same box, labelled as that item, is the item.
        var named = GoWalkthroughState()
        named.accept(GoStepProposal(kind: .step, instruction: "Click Notes in the Dock.", targetID: "screen", expected: nil,
                                    box: onNotes, label: "Notes icon"), from: withMenuBar)
        #expect(named.phase == .waiting)
        #expect(named.step?.outsideWindow == true)
        #expect(named.boxLandedOn == nil)
        // A label that names nothing in particular still takes the item under the box.
        #expect(withMenuBar.systemControlMatch(near: withMenuBar.screenRect(forBox: onNotes)!, label: "the icon")
                == .snap(withMenuBar.systemControls[3]))
    }

    @Test func aLongListKeepsTheAppsCommandsAheadOfItsContent() {
        // A toolbar, then a grid of 1,000 cells, then tabs listed after the grid.
        let toolbar = (0..<30).map { GoControl(id: "c\($0)", role: "AXButton", name: "Tool \($0)", radioSelection: nil) }
        let cells = (30..<1030).map { GoControl(id: "c\($0)", role: "AXCell", name: "\($0)", radioSelection: nil) }
        let tabs = (1030..<1033).map { GoControl(id: "c\($0)", role: "AXRadioButton", name: "Sheet \($0)", radioSelection: false) }
        let kept = GoObservation.catalogControls(toolbar + cells + tabs)
        #expect(kept.count == 200)
        #expect(kept.filter { $0.role != "AXCell" }.count == 33)        // every command, tabs included
        #expect(kept.contains { $0.name == "Sheet 1032" })
        #expect(kept.filter { $0.role == "AXCell" }.first?.name == "30") // content from the start, in order
        #expect(kept.map(\.id) == kept.sorted { Int($0.id.dropFirst())! < Int($1.id.dropFirst())! }.map(\.id))
        // Mostly commands: content still gets its reserved share.
        let manyCommands = (0..<400).map { GoControl(id: "c\($0)", role: "AXButton", name: "B\($0)", radioSelection: nil) } + cells
        #expect(GoObservation.catalogControls(manyCommands).filter { $0.role == "AXCell" }.count == 50)
        // Short lists are untouched.
        #expect(GoObservation.catalogControls(toolbar) == toolbar)
    }

    @Test func aLongMenuBarKeepsTheItemsTheRequestNames() {
        // Like Photoshop: hundreds of items, the one needed in a menu late in the bar.
        let file = (0..<150).map { GoMenuTarget(id: "m\($0)", path: ["File", "Item \($0)"]) }
        let edit = (150..<300).map { GoMenuTarget(id: "m\($0)", path: ["Edit", "Command \($0)"]) }
        let image = [GoMenuTarget(id: "m300", path: ["Image", "Crop"]), GoMenuTarget(id: "m301", path: ["Image", "Trim\u{2026}"]),
                     GoMenuTarget(id: "m302", path: ["Filter", "Blur", "Gaussian Blur\u{2026}"])]
        let kept = GoObservation.catalogMenus(file + edit + image, relevantTo: "Where do I crop this image in Photoshop?")
        #expect(kept.count == 180)
        #expect(kept.contains { $0.path == ["Image", "Crop"] })               // cut off before
        #expect(kept.map(\.id) == kept.sorted { Int($0.id.dropFirst())! < Int($1.id.dropFirst())! }.map(\.id))
        let short = Array(file.prefix(10))
        #expect(GoObservation.catalogMenus(short, relevantTo: "crop") == short)
    }

    @Test func aLongTaskShowsThePlannerEveryEarlierStep() {
        let steps = (1...20).map { GoWalkthroughStep(instruction: "Step \($0).", app: "any.app", windowToken: "w",
                                                      control: nil, menu: nil, expected: nil) }
        let earlier = GoWalkthroughCoordinator.earlierSteps(steps, shownInFull: 8)
        #expect(earlier == (1...12).map { "Step \($0)." })
        #expect(GoWalkthroughCoordinator.earlierSteps(Array(steps.prefix(5)), shownInFull: 8).isEmpty)
    }

    @Test func aMenuBarIconMatchesByAWordOfItsName() {
        var observation = self.observation
        let battery = GoSystemControl(id: "b", kind: "menuBarIcon", name: "Battery, 80 percent",
                                      frame: GoFrame(CGRect(x: 1100, y: 776, width: 26, height: 24)))
        observation.systemControls = [battery]
        #expect(observation.systemControlMatch(near: CGRect(x: 1102, y: 778, width: 20, height: 20), label: "battery icon") == .snap(battery))
    }

    @Test func aBoxIsReplacedOnlyByAControlOfComparableSizeUnderItsCentre() {
        let box = CGRect(x: 1333, y: 865, width: 143, height: 24)
        #expect(GoScreenClick.plausibleRefinement(CGRect(x: 1330, y: 850, width: 146, height: 52), of: box))
        // The whole panel, or something off to the side, is not the target.
        #expect(!GoScreenClick.plausibleRefinement(CGRect(x: 1300, y: 500, width: 400, height: 500), of: box))
        #expect(!GoScreenClick.plausibleRefinement(CGRect(x: 1000, y: 865, width: 143, height: 24), of: box))
    }

    @Test func onlyPlausiblyNamedOutsideControlsAreListed() {
        let listed = GoSystemControls.make(
            menuBar: [("Wi-Fi", CGRect(x: 1, y: 1, width: 20, height: 20)), ("", CGRect(x: 1, y: 1, width: 20, height: 20)),
                      ("Hidden", .zero), ("line\nbreak", CGRect(x: 1, y: 1, width: 20, height: 20))],
            dock: [("Notes", CGRect(x: 1, y: 1, width: 40, height: 40))])
        #expect(listed.map(\.name) == ["Wi-Fi", "Notes"])
        #expect(listed.map(\.id) == ["s0", "s1"])
        #expect(listed.map(\.kind) == ["menuBarIcon", "dockItem"])
    }

    @Test func screenClicksAreScreenedWithTheKernelsWordLists() {
        #expect(GoStepExecutor.screenTargetRefusal(label: "Export icon", instruction: "Click Export.", elementNames: []) == nil)
        #expect(GoStepExecutor.screenTargetRefusal(label: "Trash icon", instruction: "Click the bin.", elementNames: []) != nil)
        #expect(GoStepExecutor.screenTargetRefusal(label: "icon", instruction: "Click it.", elementNames: ["Empty Trash"]) != nil)
        #expect(GoStepExecutor.screenTargetRefusal(label: "Buy button", instruction: "Click Buy.", elementNames: []) != nil)
    }
}

@MainActor
struct GoVisionPlanningTests {
    private final class Sparse: @unchecked Sendable {
        func answer(_ line: String) -> String {
            if line.contains("\"menus\"") { return #"{"ok":true,"items":[{"path":["File","Save"],"enabled":true,"hasSubmenu":false}]}"# }
            let names = (0..<30).map { "Tool \($0)" }
            let object: [String: Any] = ["ok": true, "bundleIdentifier": "any.editor", "window": ["name": "Project", "token": "w"],
                "walkStopReasons": [], "focusChangedDuringWalk": false, "incompleteReads": false,
                "elements": names.map { ["role": "AXButton", "name": $0, "nameIsPlausibleLabel": true] as [String: Any] }]
            return String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
        }
    }

    private func goals() -> GoGoalStore {
        let store = GoGoalStore(url: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("goal.json"))
        _ = store.apply(GoGoalRequest(operation: .set, expectedRevision: 0, sourceQuote: "How do I export", task: "export"), heard: "How do I export")
        return store
    }

    @Test func thePlannerCanAskToSeeTheScreenAndThenPointsAtWhatItSees() async {
        let app = Sparse()
        var sent: [Bool] = []
        let coordinator = GoWalkthroughCoordinator(goals: goals(), answer: { app.answer($0) }, planner: { context in
            sent.append(context.screenshotJPEG != nil)
            if context.screenshotJPEG == nil {
                return GoStepProposal(kind: .ask, instruction: "Can I see the screen?", targetID: nil, expected: nil, needScreen: true)
            }
            return GoStepProposal(kind: .step, instruction: "Click the up-arrow Export icon.", targetID: "screen", expected: nil,
                                  box: [42, 923, 90, 952], label: "Export icon")
        }, capture: { ("/9j/AAAA", GoFrame(CGRect(x: 0, y: 0, width: 1280, height: 800))) }, frontmostApp: { "any.editor" }, logTransitions: false)
        _ = await coordinator.start()
        // Names first (30 labelled controls and a menu bar are not sparse), then the screenshot on request.
        #expect(sent == [false, true])
        #expect(coordinator.state.phase == .waiting)
        #expect(coordinator.state.step?.screenRect != nil)
        // This app needed vision once, so the next plan includes the screenshot straight away.
        coordinator.stop()
        sent = []
        _ = await coordinator.start()
        #expect(sent == [true])
    }

    @Test func anActionThatChangesNothingIsNotRepeatedForever() async {
        let app = Sparse()
        var performed = 0
        let coordinator = GoWalkthroughCoordinator(goals: goals(), answer: { app.answer($0) }, planner: { _ in
            GoStepProposal(kind: .step, instruction: "Click Tool 3.", targetID: "c3", expected: nil)
        }, capture: { nil }, frontmostApp: { "any.editor" }, logTransitions: false)
        await coordinator.runForMe { _ in performed += 1; return .done }
        // Once performed; the identical step on an unchanged screen is caught, re-planned once, then handed back.
        #expect(performed == 1)
        #expect(coordinator.state.phase == .waiting)
        #expect(coordinator.state.message.contains("nothing seemed to change"))
        #expect(!coordinator.autopilot)
    }
}

struct GoCarryOverTests {
    private func observation(_ names: [String], role: String = "AXLink") -> GoObservation {
        GoObservation(app: "any.browser", windowToken: "w", windowName: "Results", complete: true,
                      controls: names.enumerated().map { GoControl(id: "c\($0.offset)", role: role, name: $0.element, radioSelection: nil) })
    }

    @Test func aPlanSurvivesAPageThatIsStillLoading() {
        let planned = observation(["Images", "Form 10-K - sec.gov"])
        let proposal = GoStepProposal(kind: .step, instruction: "Click the 10-K link.", targetID: "c1", expected: nil)
        // Unchanged: kept as is.
        #expect(GoWalkthroughCoordinator.carryOver(proposal, planned: planned, fresh: planned)?.1.targetID == "c1")
        // More results loaded above it: same link found again, ID remapped.
        let loaded = observation(["Images", "Videos", "News", "Form 10-K - sec.gov"])
        let carried = GoWalkthroughCoordinator.carryOver(proposal, planned: planned, fresh: loaded)
        #expect(carried?.1.targetID == "c3")
        #expect(carried?.0.controls.count == 4)
        // Gone, or no longer unique: the plan is dropped and Go plans again.
        #expect(GoWalkthroughCoordinator.carryOver(proposal, planned: planned, fresh: observation(["Images"])) == nil)
        #expect(GoWalkthroughCoordinator.carryOver(proposal, planned: planned,
                                                   fresh: observation(["Form 10-K - sec.gov", "Form 10-K - sec.gov"])) == nil)
        // Targets that are not controls do not depend on the control list.
        let menu = GoStepProposal(kind: .step, instruction: "Choose File > Save.", targetID: "m0", expected: nil)
        #expect(GoWalkthroughCoordinator.carryOver(menu, planned: planned, fresh: loaded)?.1.targetID == "m0")
    }
}

@MainActor
struct GoPlanRaceTests {
    private final class Page: @unchecked Sendable {
        func answer(_ line: String) -> String {
            if line.contains("\"menus\"") { return #"{"ok":true,"items":[{"path":["File","Save"],"enabled":true,"hasSubmenu":false}]}"# }
            let object: [String: Any] = ["ok": true, "bundleIdentifier": "any.browser", "window": ["name": "Results", "token": "w"],
                "walkStopReasons": [], "focusChangedDuringWalk": false, "incompleteReads": false,
                "elements": (0..<30).map { ["role": "AXLink", "name": "Result \($0)", "nameIsPlausibleLabel": true] as [String: Any] }]
            return String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
        }
    }

    private func goals() -> GoGoalStore {
        let store = GoGoalStore(url: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("goal.json"))
        _ = store.apply(GoGoalRequest(operation: .set, expectedRevision: 0, sourceQuote: "Find the filing", task: "find the filing"), heard: "Find the filing")
        return store
    }

    @Test func theScreenshotPlanIsAlreadyRunningWhenNamesAreNotEnough() async {
        let page = Page()
        let calls = TestBox<[Bool]>([])
        let coordinator = GoWalkthroughCoordinator(goals: goals(), answer: { page.answer($0) }, planner: { context in
            calls.value.append(context.screenshotJPEG != nil)
            if context.screenshotJPEG == nil {
                return GoStepProposal(kind: .answer, instruction: "It has not been filed yet.", targetID: nil, expected: nil)
            }
            return GoStepProposal(kind: .step, instruction: "Click Result 3.", targetID: "c3", expected: nil)
        }, capture: { ("/9j/AAAA", GoFrame(CGRect(x: 0, y: 0, width: 1280, height: 800))) }, frontmostApp: { "any.browser" }, logTransitions: false)
        _ = await coordinator.start()
        #expect(Set(calls.value) == [false, true])           // both plans were requested
        #expect(coordinator.state.phase == .waiting)          // the answer from memory was not used
        #expect(coordinator.state.step?.control?.name == "Result 3")
    }

    @Test func aScrollGuessMadeWithoutLookingIsCheckedAgainstTheScreen() async {
        let page = Page()
        let coordinator = GoWalkthroughCoordinator(goals: goals(), answer: { page.answer($0) }, planner: { context in
            context.screenshotJPEG == nil
                ? GoStepProposal(kind: .reveal, instruction: "Scroll down to see the results.", targetID: nil, expected: nil, scroll: "down")
                : GoStepProposal(kind: .step, instruction: "Click Result 3.", targetID: "c3", expected: nil)
        }, capture: { ("/9j/AAAA", GoFrame(CGRect(x: 0, y: 0, width: 1280, height: 800))) }, frontmostApp: { "any.browser" }, logTransitions: false)
        _ = await coordinator.start()
        #expect(coordinator.state.step?.reveal == false)
        #expect(coordinator.state.step?.control?.name == "Result 3")
    }

    @Test func aScreenBoxFromThePlanThatSawNoScreenIsNeverUsed() async {
        let page = Page()
        let coordinator = GoWalkthroughCoordinator(goals: goals(), answer: { page.answer($0) }, planner: { context in
            context.screenshotJPEG == nil
                ? GoStepProposal(kind: .step, instruction: "Click the icon.", targetID: "screen", expected: nil, box: [0, 912, 30, 930], label: "icon")
                : GoStepProposal(kind: .step, instruction: "Click Result 3.", targetID: "c3", expected: nil)
        }, capture: { ("/9j/AAAA", GoFrame(CGRect(x: 0, y: 0, width: 1280, height: 800))) }, frontmostApp: { "any.browser" }, logTransitions: false)
        _ = await coordinator.start()
        #expect(coordinator.state.step?.screenRect == nil)
        #expect(coordinator.state.step?.control?.name == "Result 3")
    }

    @Test func twoRevealsWithoutProgressBecomeAQuestion() {
        func reveal() -> GoWalkthroughStep {
            GoWalkthroughStep(instruction: "Scroll to find Target.", app: "any.app", windowToken: "w", control: nil, menu: nil,
                              expected: nil, reveal: true)
        }
        let click = GoWalkthroughStep(instruction: "Click Insert.", app: "any.app", windowToken: "w",
                                      control: GoControl(id: "c0", role: "AXButton", name: "Insert", radioSelection: nil),
                                      menu: nil, expected: nil)
        #expect(!GoWalkthroughCoordinator.revealLoop([click, reveal()]))
        #expect(!GoWalkthroughCoordinator.revealLoop([reveal(), click]))
        #expect(GoWalkthroughCoordinator.revealLoop([click, reveal(), reveal()]))
        #expect(GoWalkthroughCoordinator.revealLoop([click, reveal(), reveal()]))
        #expect(GoWalkthroughCoordinator.revealGiveUp("the Target field").hasPrefix("I still can't see the Target field here."))
    }

    @Test func aGoodQuickPlanCancelsTheScreenshotPlan() async {
        let page = Page()
        let screenshotPlanFinished = TestBox(false)
        let coordinator = GoWalkthroughCoordinator(goals: goals(), answer: { page.answer($0) }, planner: { context in
            if context.screenshotJPEG != nil {
                try await Task.sleep(for: .seconds(2))           // cancelled before this completes
                screenshotPlanFinished.value = true
            }
            return GoStepProposal(kind: .step, instruction: "Click Result 1.", targetID: "c1", expected: nil)
        }, capture: { ("/9j/AAAA", GoFrame(CGRect(x: 0, y: 0, width: 1280, height: 800))) }, frontmostApp: { "any.browser" }, logTransitions: false)
        _ = await coordinator.start()
        #expect(coordinator.state.step?.control?.name == "Result 1")
        try? await Task.sleep(for: .milliseconds(300))
        #expect(!screenshotPlanFinished.value)
    }
}

@MainActor
struct GoReactionWaitTests {
    /// A fake app whose screen changes a set time after the owner's click.
    private final class App: @unchecked Sendable {
        private let lock = NSLock()
        private var changeAt: Date?
        func click(reactingAfter seconds: Double?) { lock.lock(); changeAt = seconds.map { Date().addingTimeInterval($0) }; lock.unlock() }
        /// The app's quick fingerprint: it changes when the app reacts.
        func pulse() -> Int { lock.lock(); defer { lock.unlock() }; return (changeAt.map { Date() >= $0 } ?? false) ? 1 : 0 }
        func answer(_ line: String) -> String {
            if line.contains("\"menus\"") { return #"{"ok":true,"items":[]}"# }
            lock.lock(); let changed = changeAt.map { Date() >= $0 } ?? false; lock.unlock()
            let names = changed ? ["Open", "Dialog"] : ["Open"]
            let object: [String: Any] = ["ok": true, "bundleIdentifier": "any.app", "window": ["name": "W", "token": "w"],
                "walkStopReasons": [], "focusChangedDuringWalk": false, "incompleteReads": false,
                "elements": names.map { ["role": "AXButton", "name": $0, "nameIsPlausibleLabel": true] as [String: Any] }]
            return String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
        }
    }

    private func run(reactingAfter seconds: Double?) async -> Duration {
        let app = App()
        let store = GoGoalStore(url: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("goal.json"))
        _ = store.apply(GoGoalRequest(operation: .set, expectedRevision: 0, sourceQuote: "Open it", task: "open it"), heard: "Open it")
        let coordinator = GoWalkthroughCoordinator(goals: store, answer: { app.answer($0) }, planner: { context in
            context.verifiedSteps.isEmpty
                ? GoStepProposal(kind: .step, instruction: "Click Open.", targetID: "c0", expected: nil)
                : GoStepProposal(kind: .done, instruction: "Done.", targetID: nil, expected: nil)
        }, capture: { nil }, frontmostApp: { "any.app" }, pulse: { app.pulse() }, logTransitions: false)
        _ = await coordinator.start()
        guard let step = coordinator.state.step else { Issue.record("no step"); return .zero }
        app.click(reactingAfter: seconds)
        let started = ContinuousClock.now
        await coordinator.targetClicked(step)
        #expect(coordinator.state.phase == .done)
        return ContinuousClock.now - started
    }

    @Test func planningStartsAsSoonAsTheAppReacts() async {
        let quick = await run(reactingAfter: 0.05)
        #expect(quick < .milliseconds(400))
    }

    @Test func anAppThatNeverReportsAChangeKeepsTheOldWait() async {
        let silent = await run(reactingAfter: nil)
        #expect(silent >= .milliseconds(450))
    }
}

@MainActor
struct GoSlowAppRepeatTests {
    /// Gmail-like: the panel the click opens appears only after a delay.
    private final class SlowPanel: @unchecked Sendable {
        private let lock = NSLock()
        private var openAt: Date?
        func clicked(appearsAfter seconds: Double) { lock.lock(); openAt = Date().addingTimeInterval(seconds); lock.unlock() }
        func answer(_ line: String) -> String {
            if line.contains("\"menus\"") { return #"{"ok":true,"items":[]}"# }
            lock.lock(); let open = openAt.map { Date() >= $0 } ?? false; lock.unlock()
            let names = open ? ["Settings", "See all settings"] : ["Settings"]
            let object: [String: Any] = ["ok": true, "bundleIdentifier": "any.mail", "window": ["name": "Inbox", "token": "w"],
                "walkStopReasons": [], "focusChangedDuringWalk": false, "incompleteReads": false,
                "elements": names.map { ["role": "AXButton", "name": $0, "nameIsPlausibleLabel": true] as [String: Any] }]
            return String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
        }
    }

    @Test func aSlowPanelDoesNotMakeGoRepeatTheStepJustDone() async {
        let app = SlowPanel()
        let store = GoGoalStore(url: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("goal.json"))
        _ = store.apply(GoGoalRequest(operation: .set, expectedRevision: 0, sourceQuote: "change my signature", task: "change signature"),
                        heard: "change my signature")
        let coordinator = GoWalkthroughCoordinator(goals: store, answer: { app.answer($0) }, planner: { context in
            // Like the real planner: without the panel, it can only say "Settings".
            if let all = context.observation.controls.first(where: { $0.name == "See all settings" }) {
                return GoStepProposal(kind: .step, instruction: "Click See all settings.", targetID: all.id, expected: nil)
            }
            return GoStepProposal(kind: .step, instruction: "Click Settings.", targetID: "c0", expected: nil)
        }, capture: { nil }, frontmostApp: { "any.mail" }, logTransitions: false)
        _ = await coordinator.start()
        guard let first = coordinator.state.step else { Issue.record("no step"); return }
        app.clicked(appearsAfter: 0.8)                     // longer than the 0.45 s reaction cap
        await coordinator.targetClicked(first)
        #expect(coordinator.state.step?.control?.name == "See all settings")
    }
}

@MainActor
struct GoRevealStepTests {
    private final class Page: @unchecked Sendable {
        func answer(_ line: String) -> String {
            if line.contains("\"menus\"") { return #"{"ok":true,"items":[{"path":["File","Print"],"enabled":true,"hasSubmenu":false}]}"# }
            let object: [String: Any] = ["ok": true, "bundleIdentifier": "any.mail", "window": ["name": "Settings", "token": "w"],
                "walkStopReasons": [], "focusChangedDuringWalk": false, "incompleteReads": false,
                "elements": (0..<30).map { ["role": "AXButton", "name": "Row \($0)", "nameIsPlausibleLabel": true] as [String: Any] }]
            return String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
        }
    }

    @Test func aRevealStepHasNoTargetAndIsNotFinishedByAClick() {
        var state = GoWalkthroughState()
        state.accept(GoStepProposal(kind: .reveal, instruction: "Scroll down to the Signature section.", targetID: nil, expected: nil,
                                    label: "Signature section", scroll: "down"),
                     from: GoObservation(app: "any.mail", windowToken: "w", windowName: "Settings", complete: true, controls: []))
        #expect(state.phase == .waiting)
        #expect(state.step?.reveal == true)
        #expect(state.step?.scrollDirection == "down")
        if let step = state.step {
            #expect(!GoGuidePresenter.completesOnClick(step))
            #expect(step.kindLabel == "reveal")
        }
    }

    @Test func afterTheOwnerScrollsTheNextPlanLooksAtTheScreen() async {
        let page = Page()
        let store = GoGoalStore(url: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("goal.json"))
        _ = store.apply(GoGoalRequest(operation: .set, expectedRevision: 0, sourceQuote: "change my signature", task: "change signature"),
                        heard: "change my signature")
        let screenshots = TestBox<[Bool]>([])
        let coordinator = GoWalkthroughCoordinator(goals: store, answer: { page.answer($0) }, planner: { context in
            screenshots.value.append(context.screenshotJPEG != nil)
            if context.verifiedSteps.isEmpty {
                return GoStepProposal(kind: .reveal, instruction: "Scroll down to Signature.", targetID: nil, expected: nil, scroll: "down")
            }
            return GoStepProposal(kind: .step, instruction: "Click Row 12.", targetID: "c12", expected: nil)
        }, capture: { ("/9j/AAAA", GoFrame(CGRect(x: 0, y: 0, width: 1280, height: 800))) }, frontmostApp: { "any.mail" }, logTransitions: false)
        _ = await coordinator.start()
        guard let reveal = coordinator.state.step else { Issue.record("no step"); return }
        screenshots.value = []
        // The presenter calls this once the owner scrolled and paused.
        await coordinator.targetClicked(reveal)
        #expect(screenshots.value.first == true)            // the plan after a scroll is made from the screen
        #expect(coordinator.state.step?.control?.name == "Row 12")
    }

    @Test func goScrollsItselfOnlyWhenADirectionIsKnown() async {
        let noDirection = GoWalkthroughStep(instruction: "Hover over the menu.", app: "any.app", windowToken: "w", control: nil, menu: nil,
                                            expected: nil, reveal: true)
        let outcome = await GoStepExecutor.perform(noDirection, answer: { _ in "{}" }, onConfirmationRequired: {})
        if case .retryable = outcome {} else { Issue.record("expected a hand-back, got \(outcome)") }
    }
}

@MainActor
struct GoPartialReadTests {
    /// A huge interface: the read hits its limits and reports itself incomplete.
    private final class HugeApp: @unchecked Sendable {
        func answer(_ line: String) -> String {
            if line.contains("\"menus\"") { return #"{"ok":true,"items":[{"path":["File","Save"],"enabled":true,"hasSubmenu":false}]}"# }
            let object: [String: Any] = ["ok": true, "bundleIdentifier": "any.ide", "window": ["name": "Project", "token": "w"],
                "walkStopReasons": ["nodeBudget"], "focusChangedDuringWalk": false, "incompleteReads": false,
                "elements": (0..<40).map { ["role": "AXButton", "name": "Tool \($0)", "nameIsPlausibleLabel": true] as [String: Any] }]
            return String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
        }
    }

    @Test func aPartialReadIsPlannedFromWithTheScreenshotInsteadOfFailing() async {
        let app = HugeApp()
        let store = GoGoalStore(url: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("goal.json"))
        _ = store.apply(GoGoalRequest(operation: .set, expectedRevision: 0, sourceQuote: "change the volume", task: "change the volume"),
                        heard: "change the volume")
        let sawScreenshot = TestBox(false)
        let coordinator = GoWalkthroughCoordinator(goals: store, answer: { app.answer($0) }, planner: { context in
            sawScreenshot.value = sawScreenshot.value || context.screenshotJPEG != nil
            return GoStepProposal(kind: .step, instruction: "Click the Control Center icon in the menu bar.", targetID: "screen",
                                  expected: nil, box: [2, 900, 28, 918], label: "Control Center icon")
        }, capture: { ("/9j/AAAA", GoFrame(CGRect(x: 0, y: 0, width: 1280, height: 800))) }, frontmostApp: { "any.ide" }, logTransitions: false)
        _ = await coordinator.start()
        #expect(sawScreenshot.value)
        #expect(coordinator.state.phase == .waiting)
        #expect(coordinator.state.step?.screenRect != nil)
    }
}
