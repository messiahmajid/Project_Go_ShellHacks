import AppKit
import ApplicationServices
import Foundation

nonisolated private final class GoAXSignal {
    let changed: @Sendable () -> Void
    init(changed: @escaping @Sendable () -> Void) { self.changed = changed }
}

nonisolated private func goWalkthroughAXChanged(_ observer: AXObserver, _ element: AXUIElement,
                                              _ name: CFString, _ context: UnsafeMutableRawPointer?) {
    guard let context else { return }
    Unmanaged<GoAXSignal>.fromOpaque(context).takeUnretainedValue().changed()
}

/// Uses AX notifications as a trigger, never as proof. A slow fallback read
/// handles apps that do not post notifications. Active only during a step.
@MainActor
private final class GoAXWatch {
    private var observer: AXObserver?
    private var signal: GoAXSignal?
    private var fallback: Task<Void, Never>?
    private var debounce: Task<Void, Never>?

    /// Notifications that mean the app's interface changed.
    private static let changeNotifications = [
        kAXWindowCreatedNotification, kAXFocusedWindowChangedNotification,
        kAXFocusedUIElementChangedNotification, kAXLayoutChangedNotification,
        kAXValueChangedNotification, kAXUIElementDestroyedNotification
    ]

    func start(app: String, changed: @escaping @MainActor () async -> Void) {
        stop()
        let callback: @Sendable () -> Void = { [weak self] in
            Task { @MainActor [weak self] in
                self?.debounce?.cancel()
                self?.debounce = Task { @MainActor in
                    do { try await Task.sleep(for: .milliseconds(250)); await changed() } catch {}
                }
            }
        }
        if let application = NSRunningApplication.runningApplications(withBundleIdentifier: app).first {
            let signal = GoAXSignal(changed: callback)
            var handle: AXObserver?
            if AXObserverCreate(application.processIdentifier, goWalkthroughAXChanged, &handle) == .success, let handle {
                self.signal = signal
                observer = handle
                let root = AXUIElementCreateApplication(application.processIdentifier)
                for name in Self.changeNotifications {
                    AXObserverAddNotification(handle, root, name as CFString, Unmanaged.passUnretained(signal).toOpaque())
                }
                CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(handle), .commonModes)
            }
        }
        fallback = Task { @MainActor in
            do {
                while !Task.isCancelled {
                    try await Task.sleep(for: .seconds(1.5))
                    await changed()
                }
            } catch {}
        }
    }

    func stop() {
        fallback?.cancel(); fallback = nil
        debounce?.cancel(); debounce = nil
        if let observer { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes) }
        observer = nil
        signal = nil
    }
}

@MainActor
final class GoWalkthroughCoordinator {
    typealias Planner = @MainActor (GoPlanningContext) async throws -> GoStepProposal
    typealias Capture = @MainActor () async -> (jpeg: String, frame: GoFrame)?
    private let goals: GoGoalStore
    private let answer: @Sendable (String) -> String
    private let planner: Planner
    private let capture: Capture
    private let frontmostApp: @MainActor () -> String?
    private let now: @MainActor () -> TimeInterval
    private let logTransitions: Bool
    private let watch = GoAXWatch()
    private(set) var state = GoWalkthroughState()
    private var generation = UUID()
    private var goalRevision: Int?
    private var reading = false
    private var suspended = false
    /// The owner finished the pointed step while a voice turn was still running
    /// (Go still speaking it). Completed when the turn ends rather than lost.
    private var clickedWhileSuspended: GoWalkthroughStep?
    /// Why the latest question was asked (a code, never UI text), for the log.
    private var askSource: String?
    var onChange: ((GoWalkthroughState) -> Void)?
    /// The owner left the pending step's screen; the presenter points them back.
    var onOffTrack: ((GoWalkthroughState) -> Void)?
    /// The last step shown, restored if planning from a new screen fails.
    private var lastStep: GoWalkthroughStep?
    /// The goal this walkthrough serves, so a refinement of it is not a new task.
    private var goalID: UUID?
    /// "Do it for me": Go performs each step itself until done, stuck, or interrupted.
    private(set) var autopilot = false
    /// Do-it-for-me stopped only to ask the owner something; their answer resumes it.
    private(set) var pausedForQuestion = false
    /// A step Go asked the owner about ("That turns off the firewall. Go ahead?").
    private(set) var awaitingApproval: GoWalkthroughStep?
    private var approvedSignatures: Set<String> = []
    /// Apps whose controls could only be found in a screenshot this session;
    /// their plans always include one.
    private var visualApps: Set<String> = []
    /// The last app the owner used other than Go, for when Go's own panel is in front.
    private var lastOwnerApp: NSRunningApplication?
    private var activationObserver: Any?
    private var phrases = GoPhrases()
    /// The step just finished, waiting for the next plan to confirm it worked:
    /// `reacted` (the screen changed), `typedMatch` (the field held the text),
    /// `byOwner` (the owner did it; praise is only for them).
    private var pendingCheck: (step: GoWalkthroughStep, reacted: Bool, typedMatch: Bool, byOwner: Bool)?
    /// The planner's verdict on the last finished step, from the latest plan.
    private(set) var lastVerdict: String?
    /// A cheap fingerprint of the app in front, to see an action land (`GoScreenPulse`).
    private let pulse: @Sendable () -> Int
    /// The app's typeable fields by label, and whether one already holds text
    /// (checked locally; the text itself is never kept).
    private let fields: @Sendable (String) -> [GoTextField]
    private let fieldHasText: @Sendable (CGRect) -> Bool
    /// The planner's working notes for the current goal (what it saw on screens
    /// that are no longer in view). Memory only; cleared with the goal.
    private(set) var notes: [String] = []
    /// A step do-it-for-me handed to the owner; once they've done it, Go carries on
    /// by itself (`onResumeAutopilot`).
    private var handedBack: GoWalkthroughStep?
    private var resumeAfterPlan = false
    /// Restarts do-it-for-me (set by the voice session, which owns how actions run).
    var onResumeAutopilot: (() -> Void)?
    /// The next plan gets the screenshot whatever else holds (set after a plan
    /// named a control that wasn't there).
    private var screenshotNextPlan = false
    /// A form being filled in: the fields still to do, in page order, each with
    /// its instruction. Go moves through them without a new plan per field.
    private var formQueue: [(field: GoTextField, instruction: String)] = []
    private var formApp: String?
    /// The planner's private checklist for the current goal; cleared with it.
    private(set) var checklist: [String] = []
    /// Short-term memory for resolving "it", "that", "there": (uptime, line).
    private var recent: [(at: TimeInterval, line: String)] = []

    /// A saved routine being replayed: which step comes next, and how many
    /// finished steps have been matched against it.
    private struct Script {
        let routine: GoRoutine
        let goalID: UUID?
        var next = 0
        var seenVerified = 0
        var misses = 0
    }
    private var script: Script?
    /// The most recently finished walkthrough, for "save this as …".
    private(set) var lastFinished: (goal: String, steps: [GoWalkthroughStep], at: TimeInterval)?
    var runningRoutineName: String? { script?.routine.name }

    /// Replays `routine` for the goal that is active now. A new goal ends it.
    func useRoutine(_ routine: GoRoutine) {
        script = Script(routine: routine, goalID: goals.activeGoal?.id)
    }

    /// What "save this as …" saves: the walkthrough in progress if it has
    /// finished steps, else the last one that finished.
    var stepsToSave: (goal: String, steps: [GoWalkthroughStep])? {
        if !state.verifiedSteps.isEmpty { return (goals.state.goal?.task ?? "", state.verifiedSteps) }
        return lastFinished.map { ($0.goal, $0.steps) }
    }

    /// When a walkthrough ended, for deciding whether "save this as X" means it.
    var secondsSinceLastFinished: TimeInterval? {
        lastFinished.map { ProcessInfo.processInfo.systemUptime - $0.at }
    }

    /// The next routine step on this screen: a ready proposal when its target is
    /// here, else a hint for the planner. Nil when no routine is replaying.
    private func routineStep(in observation: GoObservation) -> (proposal: GoStepProposal?, hint: String?)? {
        guard var current = script else { return nil }
        guard current.goalID == goals.activeGoal?.id else { script = nil; return nil }
        // Finished steps move the routine forward when they did its next step.
        let verified = state.verifiedSteps
        if verified.count > current.seenVerified {
            for done in verified[current.seenVerified...] where current.next < current.routine.steps.count {
                let wanted = current.routine.steps[current.next]
                let got = GoRoutineStep(done)
                if got.targetKey == wanted.targetKey, got.app == wanted.app || wanted.launchApp != nil || wanted.outsideName != nil {
                    current.next += 1; current.misses = 0
                } else {
                    current.misses += 1
                }
            }
            current.seenVerified = verified.count
        }
        // An app the routine opens that is already in front needs no step.
        while current.next < current.routine.steps.count, let app = current.routine.steps[current.next].launchApp,
              let front = NSRunningApplication.runningApplications(withBundleIdentifier: observation.app).first?.localizedName,
              front.caseInsensitiveCompare(app) == .orderedSame {
            current.next += 1
        }
        // Far off the recorded path: stop replaying and plan normally toward the goal.
        guard current.misses <= 4 else { script = nil; return nil }
        guard current.next < current.routine.steps.count else {
            script = nil
            let text = "That's \(current.routine.name) done."
            return (GoStepProposal(kind: verified.isEmpty ? .answer : .done, instruction: text, targetID: nil, expected: nil), nil)
        }
        script = current
        let step = current.routine.steps[current.next]
        if let local = GoRoutineReplay.proposal(for: step, in: observation) { return (local, nil) }
        return (nil, "Replaying the saved routine \"\(current.routine.name)\" (goal: \(current.routine.goal)). "
                   + "Its next recorded step (\(current.next + 1) of \(current.routine.steps.count)): " + step.hint)
    }

    /// The last two finished steps were both reveals: looking again won't help.
    nonisolated static func revealLoop(_ verified: [GoWalkthroughStep]) -> Bool {
        verified.count >= 2 && verified.suffix(2).allSatisfy(\.reveal)
    }

    nonisolated static func revealGiveUp(_ what: String?) -> String {
        let target = what ?? "what we need"
        return "I still can't see \(target) here. It may be named differently, or not included in your data or selection. What do you see instead?"
    }

    /// " in <App>" for memory lines, when the app is running.
    /// The steps before the last `shownInFull`, one line each (the step as Go
    /// described it), oldest first. Capped well inside the planner's context limit.
    nonisolated static func earlierSteps(_ steps: [GoWalkthroughStep], shownInFull: Int) -> [String] {
        Array(steps.dropLast(shownInFull).suffix(42)).map { String($0.instruction.prefix(240)) }
    }

    /// A step on something that opens a menu or panel (a menu-bar title, menu
    /// button, pop-up, combo box or disclosure): what it opened often isn't in
    /// the Accessibility lists.
    nonisolated static func opensSomething(_ step: GoWalkthroughStep) -> Bool {
        if let menu = step.menu, menu.path.count == 1 { return true }
        return ["AXMenuButton", "AXPopUpButton", "AXComboBox", "AXDisclosureTriangle"].contains(step.control?.role ?? "")
    }

    /// What a proposal targets, as a kind for the log: a listed control, menu,
    /// field or Dock/menu-bar item, a screen box, the keyboard, or nothing listed.
    nonisolated static func targetKind(of proposal: GoStepProposal, in catalog: GoObservation) -> String {
        guard let id = proposal.targetID else { return "none" }
        if id == "screen" { return "screenBox" }
        if id == "keyboard" { return "keyboard" }
        if catalog.controls.contains(where: { $0.id == id }) { return "control" }
        if catalog.menus.contains(where: { $0.id == id }) { return "menu" }
        if catalog.fields.contains(where: { $0.id == id }) { return proposal.fill == true ? "fillField" : "field" }
        if catalog.systemControls.contains(where: { $0.id == id }) { return "systemControl" }
        return "unlisted"
    }

    /// Keeps a new planner note: trimmed, at most 280 characters, not a repeat,
    /// and only the latest 10.
    nonisolated static func addingNote(_ note: String?, to notes: [String]) -> [String] {
        guard let line = note?.trimmingCharacters(in: .whitespacesAndNewlines), !line.isEmpty,
              !notes.contains(where: { $0.caseInsensitiveCompare(line) == .orderedSame }) else { return notes }
        return Array((notes + [String(line.prefix(280))]).suffix(10))
    }

    /// A checklist as kept: trimmed, non-empty lines of at most 140 characters,
    /// at most 6 of them.
    nonisolated static func cleanedChecklist(_ lines: [String]) -> [String] {
        Array(lines.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            .map { String($0.prefix(140)) }.prefix(6))
    }

    enum StepFeedback: Equatable { case praise, notYet }

    /// What to say about the step the owner just finished, from the planner's
    /// look at the screen and Go's own evidence. Nil says nothing: Go couldn't
    /// tell, so it neither praises nor corrects.
    nonisolated static func feedback(verdict: String?, check: (reacted: Bool, typedMatch: Bool),
                                     repeatsTyping: Bool, reveal: Bool) -> StepFeedback? {
        if verdict == "notYet" || repeatsTyping { return .notYet }
        if reveal { return nil }
        if verdict == "worked" { return .praise }
        // "unclear" (or an older worker): praise only with Go's own evidence.
        return check.reacted || check.typedMatch ? .praise : nil
    }

    /// Whether `next` asks for the same text, in the same app, as the step just finished.
    nonisolated static func repeatsTyping(done: GoWalkthroughStep, next: GoWalkthroughStep) -> Bool {
        guard let typed = done.typeText, let again = next.typeText, done.app == next.app else { return false }
        let squeeze = { (text: String) in text.lowercased().filter { !$0.isWhitespace } }
        return squeeze(typed) == squeeze(again)
    }

    nonisolated static func inApp(_ bundleIdentifier: String) -> String {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first?.localizedName.map { " in " + $0 } ?? ""
    }

    /// Adds a line to the planner's short-term memory (last 8 lines, 15 minutes).
    func remember(_ line: String) {
        let uptime = ProcessInfo.processInfo.systemUptime
        recent = (recent + [(uptime, line)]).filter { uptime - $0.at < 900 }.suffix(8).map { $0 }
    }

    init(goals: GoGoalStore, answer: @escaping @Sendable (String) -> String,
         planner: @escaping Planner = GoStepPlanner.plan,
         capture: @escaping Capture = GoWalkthroughCoordinator.captureScreen,
         frontmostApp: @escaping @MainActor () -> String? = { GoActiveApp.bundleIdentifier },
         now: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         pulse: @escaping @Sendable () -> Int = { GoScreenPulse.current() },
         fields: @escaping @Sendable (String) -> [GoTextField] = { GoTextFields.list(app: $0, limit: 40) },
         fieldHasText: @escaping @Sendable (CGRect) -> Bool = { rect in
             GoTextFields.contents(at: rect).map { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? false
         },
         logTransitions: Bool = true) {
        self.goals = goals; self.answer = answer; self.planner = planner; self.capture = capture
        self.frontmostApp = frontmostApp; self.now = now; self.pulse = pulse
        self.fields = fields; self.fieldHasText = fieldHasText
        self.logTransitions = logTransitions
        let own = Bundle.main.bundleIdentifier
        lastOwnerApp = NSWorkspace.shared.frontmostApplication.flatMap { $0.bundleIdentifier == own ? nil : $0 }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier != own else { return }
            MainActor.assumeIsolated { self?.lastOwnerApp = app }
        }
    }

    /// The app whose normal window is frontmost on screen, ignoring Go's own
    /// overlays: what the owner is looking at, even right after Go launched.
    nonisolated static func appOwningFrontWindow() -> NSRunningApplication? {
        let own = ProcessInfo.processInfo.processIdentifier
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return nil }
        for window in windows {   // front to back
            guard (window[kCGWindowLayer as String] as? Int) == 0,
                  let pid = window[kCGWindowOwnerPID as String] as? pid_t, pid != own,
                  let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy == .regular else { continue }
            return app
        }
        return nil
    }

    /// Go never reads its own interface. When Go's panel is in front, the owner
    /// means the app they were just using: bring it back before reading.
    /// With no such app (asking from an empty desktop), Finder, which owns the
    /// desktop, takes the front.
    private func frontOwnersApp() async {
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == Bundle.main.bundleIdentifier,
              let app = (lastOwnerApp.flatMap { $0.isTerminated ? nil : $0 }) ?? Self.appOwningFrontWindow()
                ?? NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first else { return }
        app.activate()
        for _ in 0..<10 where NSWorkspace.shared.frontmostApplication?.processIdentifier != app.processIdentifier {
            try? await Task.sleep(for: .milliseconds(40))
        }
    }

    /// The owner's display without Go's overlay, downscaled. Nothing is captured
    /// while a password field has focus.
    static func captureScreen() async -> (jpeg: String, frame: GoFrame)? {
        // Unit tests never photograph the machine running them.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return nil }
        if let app = GoActiveApp.bundleIdentifier,
           await Task.detached(operation: { GoTextFields.secureFieldFocused(app: app) }).value { return nil }
        // Just the app being used (its windows and anything they opened): a smaller,
        // sharper picture than the whole display. The whole display when the app
        // fills most of it, or when its area can't be found.
        if let bundle = GoActiveApp.bundleIdentifier,
           let pid = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first?.processIdentifier,
           let region = ScreenCaptureUtility.appRegion(pid: pid),
           let display = NSScreen.screens.first(where: { $0.frame.intersects(region) })?.frame,
           region.intersection(display).width * region.intersection(display).height < display.width * display.height * 0.85,
           let shot = try? await ScreenCaptureUtility.captureRegionAsJPEG(region),
           let jpeg = RealtimeOpenAppTool.downscaledJPEG(shot.data, maxPixelDimension: 1280), jpeg.count <= 700_000 {
            return (jpeg.base64EncodedString(), GoFrame(shot.frame))
        }
        guard let screen = try? await ScreenCaptureUtility.captureAllScreensAsJPEG().first,
              let jpeg = RealtimeOpenAppTool.downscaledJPEG(screen.imageData, maxPixelDimension: 1280),
              jpeg.count <= 700_000 else { return nil }
        return (jpeg.base64EncodedString(), GoFrame(screen.displayFrame))
    }

    func start() async -> [String: Any] {
        stop()
        guard goals.activeGoal != nil else { return ["ok": false, "message": "Tell me your goal first."] }
        state = GoWalkthroughState(); notes = []; checklist = []; formQueue = []
        goalRevision = goals.state.revision
        goalID = goals.activeGoal?.id
        pendingCheck = nil
        await planNext(generation: generation)
        return status()
    }

    /// "I did it", "what's next", "continue": the pending step counts as done
    /// and the next one is planned from the screen, keeping earlier steps.
    func proceed(ownerAnswered: Bool = false) async -> [String: Any] {
        // The owner's answer to Go's own question refines the same goal: keep the
        // walkthrough and its completed steps rather than starting over.
        if ownerAnswered, let goal = goals.activeGoal, goal.id == goalID { goalRevision = goals.state.revision }
        guard goals.activeGoal != nil, goalRevision == goals.state.revision,
              state.phase != .stopped, state.phase != .idle else { return await start() }
        if state.phase == .waiting, let step = state.step, state.completeByClick(step) {
            // "I did it": the next plan checks it before any praise.
            pendingCheck = (step, false, false, true)
            noteOwnerFinished(step)
        }
        generation = UUID()
        watch.stop()
        if state.phase == .done { publish(); return status() }
        await planNext(generation: generation)
        return status()
    }

    func stop() {
        clickedWhileSuspended = nil
        handedBack = nil
        resumeAfterPlan = false
        autopilot = false
        pausedForQuestion = false
        awaitingApproval = nil
        generation = UUID()
        watch.stop()
        state.stop("Walkthrough stopped.")
        publish()
    }

    func suspend() {
        // Talking to Go always takes the controls back.
        autopilot = false
        suspended = true; watch.stop()
        // An automatic plan must not surface after a newer owner turn.
        if state.phase == .planning { generation = UUID() }
    }
    func resume() {
        suspended = false
        guard goalRevision == goals.state.revision, goals.activeGoal != nil else { stop(); return }
        if let clicked = clickedWhileSuspended {
            clickedWhileSuspended = nil
            if state.phase == .waiting, state.step == clicked, state.completeByClick(clicked) { publish() }
        }
        if state.phase == .planning {
            let token = generation
            Task { [weak self] in await self?.planNext(generation: token) }
        } else { armWatch() }
    }

    func status() -> [String: Any] {
        ["ok": true, "phase": state.phase.rawValue, "instruction": state.message,
         "verifiedStepCount": state.verifiedSteps.count, "uiChangedByGo": false]
    }

    private var rememberedSteps = 0
    private func publish() {
        if state.phase == .done, !state.verifiedSteps.isEmpty {
            lastFinished = (goals.state.goal?.task ?? "", state.verifiedSteps, ProcessInfo.processInfo.systemUptime)
        }
        // Finished steps join the short-term memory ("open it" after a point, "do the same").
        if state.verifiedSteps.count > rememberedSteps, let last = state.verifiedSteps.last {
            remember("Completed: " + last.targetDescription + Self.inApp(last.app))
        }
        rememberedSteps = state.verifiedSteps.count
        if logTransitions {
            MeasurementLogFile.appendJSONLine(["kind": "walkthrough", "phase": state.phase.rawValue,
                "time": Date().timeIntervalSince1970, "session": generation.uuidString,
                "verifiedStepCount": state.verifiedSteps.count,
                // The kind of step shown (fill, field, keyboard, control…), never its words.
                "stepKind": state.step?.kindLabel ?? NSNull(),
                "askSource": state.phase == .needsInput ? (askSource ?? state.askCode ?? "planner") : NSNull()], toFileNamed: "go-walkthrough.log")
        }
        onChange?(state)
    }

    /// `allowPartial`: planning may use a read that hit the walk's size or time
    /// limits (very large interfaces); checking that a step happened never does.
    /// Harness answers that mean "there's no window here to read".
    nonisolated static let noWindowErrors: Set<String> = ["noFocusedWindow", "targetIsHarnessItself", "noRootNode"]

    /// The screen when no app window can be read: the app in front (Finder when
    /// it's Go itself or nothing), with no window controls. Menus, menu-bar icons,
    /// the Dock and the screenshot are added as for any planning read.
    nonisolated static func desktopObservation() -> GoObservation {
        let own = Bundle.main.bundleIdentifier
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let app = front == nil || front == own ? "com.apple.finder" : front!
        return GoObservation(app: app, windowToken: "desktop", windowName: "Desktop", complete: true, controls: [])
    }

    /// A harness request that can't hold Go up: an app that doesn't answer within
    /// `limit` gives nil, and Go carries on (tries again, then says the app isn't
    /// responding) instead of freezing. Reads slower than 3 s are logged by verb.
    /// How long a planning read may take before Go stops waiting (shorter in tests).
    var readTimeLimit: Duration = .seconds(10)

    private func timedHarness(_ line: String, verb: String) async -> String? {
        let limit = readTimeLimit
        let answer = self.answer
        let started = ContinuousClock.now
        // Whichever comes first, the answer or the limit. A stuck read can't be
        // cancelled, so it is left to finish on its own; Go doesn't wait for it.
        let result: String? = await withCheckedContinuation { continuation in
            let first = FirstAnswer(continuation)
            Task.detached { first.give(answer(line)) }
            Task.detached { try? await Task.sleep(for: limit); first.give(nil) }
        }
        let elapsed = ContinuousClock.now - started
        if logTransitions, elapsed > .seconds(3) {
            let ms = Int(elapsed.components.seconds * 1000) + Int(elapsed.components.attoseconds / 1_000_000_000_000_000)
            MeasurementLogFile.appendJSONLine(["kind": "slowRead", "time": Date().timeIntervalSince1970, "verb": verb,
                                               "ms": ms, "timedOut": result == nil], toFileNamed: "go-walkthrough.log")
        }
        return result
    }

    /// How long the last planning read spent on the element walk and on the
    /// rest (menus, fields, Dock and menu-bar icons), for the timing log.
    private var lastReadSplit: (walkMs: Int, extrasMs: Int)?

    private func readObservation(menus: Bool, expectedApp: String? = nil, allowPartial: Bool = false) async throws -> GoObservation {
        let startedAt = ProcessInfo.processInfo.systemUptime
        var request: [String: Any] = ["verb": "snapshot"]
        if let expectedApp { request["expectApp"] = expectedApp }
        let line = String(decoding: try JSONSerialization.data(withJSONObject: request), as: UTF8.self)
        let answer = self.answer
        guard let response = await timedHarness(line, verb: "snapshot") else {
            throw GoVoiceFailure(kind: "walkthrough:appNotResponding")
        }
        let object = RealtimeOpenAppTool.harnessResponseObject(response)
        var decoded = GoObservation.decode(object)
        // No window to read (the empty desktop, an app with its windows closed, or
        // Go itself in front): planning still has the menus, the menu-bar icons,
        // the Dock and the screenshot, which is all a question about the Mac needs.
        if decoded == nil, menus, Self.noWindowErrors.contains(object["error"] as? String ?? "") {
            decoded = Self.desktopObservation()
        }
        guard var observation = decoded, observation.complete || allowPartial else {
            throw GoVoiceFailure(kind: "walkthrough:unreadableInterface")
        }
        let walkedAt = ProcessInfo.processInfo.systemUptime
        // Planning only: labels of typeable fields, never their contents. Read
        // alongside the menu bar rather than after it.
        let fieldsApp = observation.app
        let fieldsTask: Task<[GoTextField], Never>? = menus ? Task.detached { [fields] in fields(fieldsApp) } : nil
        let systemTask: Task<[GoSystemControl], Never>? = menus ? Task.detached { GoSystemControls.current() } : nil
        if menus {
            let menuLine = String(decoding: try JSONSerialization.data(withJSONObject: ["verb": "menus", "expectApp": observation.app]), as: UTF8.self)
            // Menus are extra: an app that doesn't answer in time just has none this read.
            let menuResponse = RealtimeOpenAppTool.harnessResponseObject(await timedHarness(menuLine, verb: "menus") ?? "")
            if menuResponse["ok"] as? Bool == true {
                let items = menuResponse["items"] as? [[String: Any]] ?? []
                observation.menus = items.enumerated().compactMap { index, item in
                    guard item["enabled"] as? Bool == true, item["hasSubmenu"] as? Bool == false,
                          let path = item["path"] as? [String], !path.isEmpty,
                          !RealtimeVoiceVerbs.isPrivateMenuItem(path: path, shortcut: item["shortcut"] as? String),
                          path.allSatisfy({ UntrustedText($0).isPlausibleControlLabel }) else { return nil }
                    return GoMenuTarget(id: "m\(index)", path: path)
                }
            }
        }
        if let fieldsTask { observation.fields = await fieldsTask.value }
        if let systemTask { observation.systemControls = await systemTask.value }
        if menus {
            let now = ProcessInfo.processInfo.systemUptime
            lastReadSplit = (Int(((walkedAt - startedAt) * 1000).rounded()), Int(((now - walkedAt) * 1000).rounded()))
        }
        return observation
    }

    private func planNext(generation token: UUID, prefix: String? = nil, attempt: Int = 0) async {
        watch.stop()
        guard token == generation, goalRevision == goals.state.revision, let goal = goals.activeGoal else { return }
        guard state.verifiedSteps.count < 50 else { state.ask("Let's check the goal before continuing.", code: "stepLimit"); publish(); return }
        askSource = nil
        state.planning(); publish()
        do {
            // The screen picture is taken alongside the structural read: the planner
            // sees context and icons that have no Accessibility name.
            let startedAt = ProcessInfo.processInfo.systemUptime
            let captureTask = Task { await self.capture() }
            await frontOwnersApp()
            var observation = try await readObservation(menus: true, allowPartial: true)
            let readAt = ProcessInfo.processInfo.systemUptime
            let pulseAtRead = await Task.detached { [pulse] in pulse() }.value
            let shot = await captureTask.value
            let capturedAt = ProcessInfo.processInfo.systemUptime
            observation.screenFrame = shot?.frame
            guard token == generation, goalRevision == goals.state.revision else { return }
            let catalog = GoObservation(app: observation.app, windowToken: observation.windowToken, windowName: observation.windowName,
                                        complete: observation.complete, controls: GoObservation.catalogControls(observation.controls),
                                        menus: GoObservation.catalogMenus(observation.menus, relevantTo: goal.rawGoal + " " + goal.lastInstruction),
                                        fields: observation.fields,
                                        screenFrame: observation.screenFrame, systemControls: observation.systemControls)
            var context = GoPlanningContext(goal: goal, observation: catalog,
                                            verifiedSteps: Array(state.verifiedSteps.suffix(8)),
                                            catalogLimited: catalog.controls.count < observation.controls.count || catalog.menus.count < observation.menus.count,
                                            earlierSteps: Self.earlierSteps(state.verifiedSteps, shownInFull: 8), notes: notes,
                                            checklist: checklist)
            // Screenshots cost about 3 s per plan, so they are sent when names aren't
            // enough: sparse accessibility, apps that needed one before, or on request.
            let sparse = catalog.controls.count < 20 || (catalog.menus.isEmpty && catalog.controls.count < 40)
            // After a reveal (a scroll), what is now visible is the whole question.
            let afterReveal = state.verifiedSteps.last?.reveal == true
            // What a menu button, pop-up or disclosure opened (a dropdown, gallery,
            // panel) is often outside the lists: the next plan needs to see it.
            let afterOpener = state.verifiedSteps.last.map(Self.opensSomething) ?? false
            // Fields without names (PDF and many web forms): only the picture shows
            // the printed label beside each box.
            let unnamedFields = observation.fields.contains { $0.label.trimmingCharacters(in: .whitespaces).isEmpty }
            let asked = screenshotNextPlan
            screenshotNextPlan = false
            // A partial read (a very large interface) leans on the screenshot too.
            if sparse || afterReveal || afterOpener || asked || unnamedFields || !observation.complete || visualApps.contains(observation.app) {
                context.screenshotJPEG = shot?.jpeg
            }
            context.recent = recent.map(\.line)
            // A replaying routine's step that is on this screen needs no planner.
            let replay = routineStep(in: observation)
            context.routineHint = replay?.hint
            // The screenshot plan runs alongside the names-only plan. The quick plan is
            // used when it is a real step; otherwise the screenshot plan decides.
            var visionPlan: Task<GoStepProposal, Error>?
            if replay?.proposal == nil, context.screenshotJPEG == nil, let jpeg = shot?.jpeg {
                var withScreen = context
                withScreen.screenshotJPEG = jpeg
                let planner = self.planner
                visionPlan = Task { try await planner(withScreen) }
            }
            var proposal: GoStepProposal
            if let local = replay?.proposal { proposal = local } else { proposal = try await planner(context) }
            guard token == generation, goalRevision == goals.state.revision, !Task.isCancelled else { visionPlan?.cancel(); return }
            if let visionPlan {
                // Answers, reveals and app launches are claims about the screen, so the
                // screenshot plan decides them.
                // A screenshot box from the plan that never saw the screen is a guess.
                // So is "the last step didn't work": judged blind, it sends the owner
                // down another route after a step that did work.
                if proposal.needScreen == true || proposal.kind == .answer || proposal.kind == .reveal || proposal.kind == .launch
                    || proposal.targetID == "screen" || proposal.lastStep == "notYet" {
                    proposal = try await visionPlan.value
                    context.screenshotJPEG = shot?.jpeg
                } else {
                    visionPlan.cancel()
                }
            }
            // Two reveals in a row that didn't turn up the target: stop sending the
            // owner to look again, and say so.
            if proposal.kind == .reveal, Self.revealLoop(state.verifiedSteps) {
                let what = proposal.label.flatMap { UntrustedText($0).isPlausibleControlLabel ? $0 : nil }
                proposal = GoStepProposal(kind: .ask, instruction: Self.revealGiveUp(what), targetID: nil, expected: nil)
                askSource = "revealLoop"
            }
            // Boxes are only trusted from a plan that saw the screenshot.
            if context.screenshotJPEG == nil { observation.screenFrame = nil }
            // The step just completed again usually means the app hadn't redrawn yet:
            // wait for the change and plan once more.
            if attempt == 0, !autopilot, let done = state.verifiedSteps.last, !done.reveal, observation.contextHash == done.contextHash,
               let repeatSignature = Self.signature(of: proposal, in: observation), repeatSignature == done.signature {
                await waitForReaction(from: observation.contextHash, cap: .milliseconds(1200), after: "repeat")
                guard token == generation else { return }
                return await planNext(generation: token, prefix: prefix, attempt: attempt + 1)
            }
            if proposal.targetID == "screen" { visualApps.insert(observation.app) }
            if logTransitions {
                let now = ProcessInfo.processInfo.systemUptime
                func ms(_ from: TimeInterval, _ to: TimeInterval) -> Int { Int(((to - from) * 1000).rounded()) }
                MeasurementLogFile.appendJSONLine(["kind": "timing", "time": Date().timeIntervalSince1970,
                    "readMs": ms(startedAt, readAt), "captureWaitMs": ms(readAt, capturedAt), "planMs": ms(capturedAt, now),
                    "vision": context.screenshotJPEG != nil, "controls": catalog.controls.count,
                    "observedControls": observation.controls.count, "walkMs": lastReadSplit?.walkMs ?? -1,
                    "extrasMs": lastReadSplit?.extrasMs ?? -1, "lastStep": proposal.lastStep ?? "none",
                    // Counts only: notes and checklist hold screen content, which is never logged.
                    "notes": Self.addingNote(proposal.note, to: notes).count, "noted": proposal.note != nil,
                    "checklistLines": proposal.checklist?.count ?? checklist.count,
                    "checklistDone": (proposal.checklist ?? checklist).filter { $0.lowercased().hasPrefix("done:") }.count,
                    "checklistChanged": proposal.checklist != nil,
                    "providerMs": proposal.usage?.providerMs ?? -1, "promptTokens": proposal.usage?.promptTokens ?? -1,
                    "imageTokens": proposal.usage?.imageTokens ?? -1, "thinkingTokens": proposal.usage?.thinkingTokens ?? -1,
                    "outputTokens": proposal.usage?.outputTokens ?? -1,
                    // What the planner answered, as kinds only: the answer and what it targeted.
                    "proposalKind": proposal.kind.rawValue, "target": Self.targetKind(of: proposal, in: catalog)], toFileNamed: "go-walkthrough.log")
            }
            guard token == generation, goalRevision == goals.state.revision, !Task.isCancelled else { return }
            // Launch steps name an app, and screen steps a box on the screenshot
            // (validated in accept); every other target must be an observed ID.
            if proposal.kind == .step || proposal.kind == .point, proposal.targetID != "screen", proposal.targetID != "keyboard",
               !catalog.controls.contains(where: { $0.id == proposal.targetID }) && !catalog.menus.contains(where: { $0.id == proposal.targetID })
               && !catalog.fields.contains(where: { $0.id == proposal.targetID })
               && !catalog.systemControls.contains(where: { $0.id == proposal.targetID }) {
                // A made-up target (usually something that just opened and isn't in the
                // lists): look again with the screenshot before troubling the owner.
                if attempt == 0 {
                    remember("Go's last plan named a control that isn't listed; choose from the lists, or box it on the screenshot.")
                    screenshotNextPlan = true
                    return await replan(token, prefix: prefix, attempt: attempt,
                                        reason: "I can't find that on screen right now. What's it called, or what does it look like?")
                }
                state.ask("I can't find that on screen right now. What's it called, or what does it look like?", code: "targetNotObserved")
                publish(); return
            }
            // Recheck the same interface after the network call. The proposal's
            // IDs belong to the earlier catalogue and must not be reinterpreted.
            // When the quick fingerprint shows nothing moved while planning, the
            // screen is the one planned from, and the full re-read is skipped.
            let pulseNow = await Task.detached { [pulse] in pulse() }.value
            let unchanged = pulseAtRead != 0 && pulseAtRead == pulseNow
            let fresh = unchanged ? observation
                : try await readObservation(menus: false, expectedApp: observation.app, allowPartial: true)
            guard token == generation, goalRevision == goals.state.revision, !Task.isCancelled else { return }
            // A page that is still loading must not cost a whole new plan: the plan
            // stands if its target is still there, found again by role and name.
            guard fresh.windowToken == observation.windowToken,
                  let (settled, settledProposal) = Self.carryOver(proposal, planned: observation, fresh: fresh) else {
                return await replan(token, prefix: prefix, attempt: attempt, reason: "The screen kept changing. Ask me again when it settles.")
            }
            observation = settled
            proposal = settledProposal
            state.accept(proposal, from: observation)
            GoRunRecorder.record(context: context, observation: observation, proposal: proposal, state: state)
            if let item = state.boxLandedOn {
                // The box fell on a Dock or menu-bar item the plan didn't mean: say so
                // to the planner and look again, rather than act on another app.
                let place = item.kind == "dockItem" ? "the Dock item" : "the menu-bar icon"
                remember("A screen box fell on \(place) \u{201C}\(item.name)\u{201D}, which was not the target; "
                         + "box the target inside the app's own window.")
                askSource = "boxOnSystemItem"
                return await replan(token, prefix: prefix, attempt: attempt, reason: GoWalkthroughState.cantPlaceIt)
            }
            if state.boxRejected {
                // An unusable box (malformed, tiny, or the whole picture): one more look,
                // told why, before asking the owner.
                askSource = "boxRejected"
                if attempt == 0 {
                    remember("Go's last screen box couldn't be used (malformed, tiny, or most of the picture); box only the control itself, tightly.")
                    screenshotNextPlan = true
                    return await replan(token, prefix: prefix, attempt: attempt, reason: GoWalkthroughState.cantPlaceIt)
                }
            }
            state.stamp(observation.contextHash, windowFrame: observation.windowFrame)
            // A screenshot box is an estimate: use the exact frame of the control under it.
            if state.phase == .waiting, let rough = state.step?.screenRect?.rect, state.step?.outsideWindow == false,
               let exact = await Task.detached(operation: { GoScreenClick.elementFrame(near: rough) }).value {
                guard token == generation else { return }
                state.refineScreenRect(exact)
            }
            state.applyRisk(proposal.risk, warnOwner: !autopilot)
            // The last step, checked against this screen before any praise.
            lastVerdict = proposal.lastStep
            notes = Self.addingNote(proposal.note, to: notes)
            if let form = proposal.formFields, !form.isEmpty {
                formQueue = form.compactMap { entry in
                    observation.fields.first { $0.id == entry.id }.map { ($0, String(entry.instruction.prefix(240))) }
                }
                formApp = observation.app
            }
            if let revised = proposal.checklist { checklist = Self.cleanedChecklist(revised) }
            if let check = pendingCheck, check.step == state.verifiedSteps.last {
                pendingCheck = nil
                if check.byOwner, !autopilot, prefix == nil,
                   let feedback = Self.feedback(verdict: proposal.lastStep, check: (check.reacted, check.typedMatch),
                                                repeatsTyping: state.step.map { Self.repeatsTyping(done: check.step, next: $0) } ?? false,
                                                reveal: check.step.reveal) {
                    state.prefixMessage(feedback == .notYet ? "Not quite yet. " : phrases.say(.stepDone) + " ")
                }
            }
            if state.phase == .waiting, let step = state.step {
                remember((step.final ? "Go pointed at " : "Go's next step: ") + step.targetDescription + Self.inApp(step.app))
            }
            if let prefix { state.prefixMessage(prefix) }
            if state.phase == .waiting { lastStep = state.step }
            publish()
            armWatch()
            if resumeAfterPlan {
                resumeAfterPlan = false
                // The step was just planned from the current screen: act on it as is.
                if state.phase == .waiting, !autopilot { pausedForQuestion = true; onResumeAutopilot?() }
            }
        } catch {
            guard token == generation else { return }
            // Right after a click the app is often mid-change; read again before giving up.
            let notResponding = (error as? GoVoiceFailure)?.kind == "walkthrough:appNotResponding"
            if notResponding { askSource = "appNotResponding" }
            await replan(token, prefix: prefix, attempt: attempt,
                         reason: notResponding ? "That app isn't responding to me right now. Give it a moment, then ask me again."
                                               : "I couldn't get a clear look at the screen just then. Click the window you're working in, then ask me again.")
        }
    }

    /// The owner really is somewhere else and cannot be pointed back:
    /// plan from here, falling back to the pending step if that fails.
    /// The owner clicked something other than the pointed control and the app
    /// changed: plan the next step from this screen, without "not quite" (their
    /// way may have been right; the next plan judges).
    func followOwnersWay() async {
        guard state.phase == .waiting, !suspended, !autopilot else { return }
        let token = generation
        state.planning(); publish()
        await planNext(generation: token)
    }

    func replanFromHere() async {
        guard state.phase == .waiting, !suspended else { return }
        let token = generation
        state.planning(); publish()
        await planNext(generation: token, prefix: phrases.say(.offTrack) + " ")
    }

    /// What a proposal would act on, in the same form as `GoWalkthroughStep.signature`.
    nonisolated static func signature(of proposal: GoStepProposal, in observation: GoObservation) -> String? {
        guard proposal.kind == .step || proposal.kind == .point else { return nil }
        var probe = GoWalkthroughState()
        probe.accept(proposal, from: observation)
        return probe.step?.signature
    }

    /// Re-bases a plan on the fresh read taken after planning. Unchanged controls
    /// keep it as is. Otherwise a control target is found again by role and name
    /// (it must be unique) and its ID remapped; menu, field, screenshot and launch
    /// targets do not depend on the control list. Nil when the target is gone.
    nonisolated static func carryOver(_ proposal: GoStepProposal, planned: GoObservation, fresh: GoObservation)
        -> (GoObservation, GoStepProposal)? {
        if fresh.controls == planned.controls { return (planned, proposal) }
        var rebased = fresh
        rebased.menus = planned.menus
        rebased.fields = planned.fields
        rebased.screenFrame = planned.screenFrame
        rebased.systemControls = planned.systemControls
        if rebased.windowFrame == nil { rebased.windowFrame = planned.windowFrame }
        guard let id = proposal.targetID, let control = planned.controls.first(where: { $0.id == id }) else {
            return (rebased, proposal)
        }
        let matches = fresh.matches(role: control.role, name: control.name)
        guard matches.count == 1 else { return nil }
        var moved = proposal
        moved.targetID = matches[0].id
        return (rebased, moved)
    }

    /// The owner is still clicking while Go plans: read again rather than give up.
    private func replan(_ token: UUID, prefix: String?, attempt: Int, reason: String) async {
        guard attempt < 3 else {
            // Never strand the owner: fall back to the last step if it is still this goal's.
            if let lastStep, goalRevision == goals.state.revision, goals.activeGoal != nil {
                state.restore(lastStep, message: phrases.say(.goBack) + " " + lastStep.instruction)
                publish(); armWatch(); return
            }
            state.ask(reason, code: askSource ?? "readOrPlanFailed"); publish(); return
        }
        try? await Task.sleep(for: .milliseconds(400))
        guard token == generation else { return }
        await planNext(generation: token, prefix: prefix, attempt: attempt + 1)
    }

    /// Performs every remaining step: show it, act through the harness, wait for
    /// the UI, plan the next step. A failed step is re-planned once; a second
    /// failure or a safety refusal hands the step to the owner.
    /// `pointerSettled` returns once the pointer has landed on the step's target,
    /// so every action happens where the owner is looking.
    func runForMe(perform: @escaping @MainActor (GoWalkthroughStep) async -> GoStepExecutor.Outcome,
                  pointerSettled: @escaping @MainActor () async -> Void = { try? await Task.sleep(for: .milliseconds(250)) }) async {
        guard goals.activeGoal != nil else { return }
        if goalRevision != goals.state.revision || state.phase == .stopped || state.phase == .idle {
            // A new or restarted task begins from the current screen.
            generation = UUID(); state = GoWalkthroughState(); notes = []; checklist = []; formQueue = []; goalRevision = goals.state.revision; goalID = goals.activeGoal?.id
        }
        // Resuming after Go's own question ("want me to go ahead?") performs that
        // step. Taking over a step Go was showing performs it too, when the screen
        // is as it was planned. Only when the screen changed (the owner may have
        // done it, or part of it) does Go look again, so it never clicks twice,
        // and never throws away a good step for a second guess.
        let resuming = pausedForQuestion
        autopilot = true
        pausedForQuestion = false
        watch.stop()
        suspended = false
        var lookAgain = state.phase != .waiting
        if state.phase == .waiting, !resuming, let shown = state.step {
            let now = try? await readObservation(menus: false, expectedApp: shown.app, allowPartial: true)
            lookAgain = now.map { $0.contextHash != shown.contextHash || $0.windowToken != shown.windowToken } ?? true
        }
        if lookAgain { await planNext(generation: generation) }
        var failures = 0
        var notTakingEffect = 0
        var lastDone: (signature: String, context: Int)?
        while autopilot, !Task.isCancelled, state.phase == .waiting, let step = state.step {
            let token = generation
            // Let the pointer land so the owner sees what Go is about to do.
            await pointerSettled()
            guard autopilot, token == generation, state.step == step else { break }
            // "confirm" steps wait for the owner's yes, unless the kernel will show its
            // own card for this target anyway (never ask twice).
            if step.risk?.level == .confirm, !approvedSignatures.contains(step.signature), !kernelWillAsk(step) {
                awaitingApproval = step
                let what = step.risk?.reason.flatMap { UntrustedText($0).isPlausibleControlLabel ? $0 : nil } ?? "this changes something important"
                state.askBeforeStep("Before I do that: it \(what.lowercased()). Want me to go ahead?")
                publish()
                break
            }
            // The owner's own details go in their own hands: hand the field over
            // without calling it a failure, and carry on once they've filled it.
            if step.fill {
                autopilot = false
                handedBack = step
                state.restore(step, message: step.instruction)
                publish()
                armWatch()
                return
            }
            // A pointer-only step ("here's the slider") is where the owner sets
            // something Go can't know, like a level: show it and hand it over.
            if step.final {
                autopilot = false
                state.prefixMessage("Over to you: ")
                publish()
                break
            }
            // The same action on an unchanged screen means the last one did nothing.
            let repeated = lastDone.map { $0.signature == step.signature && $0.context == step.contextHash } ?? false
            let beforeAction = await Task.detached { [pulse] in pulse() }.value
            let outcome = repeated ? .retryable("nothing seemed to change") : await perform(step)
            if logTransitions {
                MeasurementLogFile.appendJSONLine(["kind": "autopilot", "time": Date().timeIntervalSince1970, "stepKind": step.kindLabel,
                                                   "outcome": "\(outcome)"], toFileNamed: "go-walkthrough.log")
            }
            guard autopilot, token == generation, state.step == step else { break }
            switch outcome {
            case .done:
                failures = 0
                lastDone = (step.signature, step.contextHash)
                let reacted = await waitForPulse(from: beforeAction, cap: .milliseconds(300), after: "act")
                guard autopilot, token == generation, state.completeByClick(step) else { break }
                pendingCheck = (step, reacted, false, false)
                publish()
                if state.phase == .planning { await planNext(generation: token) }
                // Go's action "succeeded" but the planner saw no effect, twice in a
                // row: stop repeating it and hand it over rather than loop.
                notTakingEffect = lastVerdict == "notYet" ? notTakingEffect + 1 : 0
                if notTakingEffect >= 2, autopilot, token == generation, state.phase == .waiting, let again = state.step {
                    autopilot = false
                    askSource = "autopilotNoEffect"
                    state.restore(again, message: "I tried that, but it didn't take. Can you do this one? I'll carry on after. " + again.instruction)
                    handedBack = state.step
                    publish()
                    armWatch()
                    return
                }
            case .retryable(let reason) where failures == 0:
                failures = 1
                _ = reason
                // Self-correct: read the screen again and choose again.
                state.planning(); publish()
                await planNext(generation: token)
            case .declined:
                // The owner said no (or didn't say yes) to Go's own question: that ends it.
                autopilot = false
                askSource = nil
                state.finish("Okay, I've left it as it is.")
                publish()
                return
            case .retryable(let reason), .blocked(let reason):
                autopilot = false
                askSource = "autopilotStopped"
                state.restore(step, message: "I couldn't do this one: \(reason). Can you do it? I'll carry on after. " + step.instruction)
                handedBack = state.step
                publish()
                armWatch()
                return
            }
        }
        // A question from the planner (or Go's own "go ahead?") pauses the run rather than ending it.
        pausedForQuestion = (autopilot && state.phase == .needsInput) || awaitingApproval != nil
        autopilot = false
        if state.phase == .waiting { armWatch() }
    }

    private func kernelWillAsk(_ step: GoWalkthroughStep) -> Bool {
        let name = (step.control?.name ?? step.menu?.path.joined(separator: " ") ?? step.screenLabel ?? "").lowercased()
        return ActionSafetyKernel.destructiveTitleKeywords.contains { name.contains($0) }
    }

    /// The owner's yes or no to `awaitingApproval`. Yes restores the step and lets
    /// do-it-for-me continue; no leaves it for the owner.
    func answerApproval(_ yes: Bool) {
        guard let step = awaitingApproval else { return }
        awaitingApproval = nil
        if yes {
            approvedSignatures.insert(step.signature)
            state.restore(step, message: step.instruction)
            pausedForQuestion = true
        } else {
            pausedForQuestion = false
            state.restore(step, message: "Okay, I'll leave that one to you. " + step.instruction)
            publish()
            armWatch()
        }
    }

    /// Called when the owner clicks the pointed final target.
    func targetClicked(_ step: GoWalkthroughStep) async {
        guard !autopilot else { return }
        let token = generation
        // The owner's click is seen on mouse-down; apps act on mouse-up. The screen
        // read now is the one the click will replace, even on a page that kept
        // loading after this step was planned.
        let atClick = await Task.detached { [pulse] in pulse() }.value
        let reacted = await waitForPulse(from: atClick, cap: .milliseconds(450), after: "click")
        guard token == generation, !autopilot, goalRevision == goals.state.revision else { return }
        if suspended {
            if state.phase == .waiting, state.step == step { clickedWhileSuspended = step }
            return
        }
        guard state.completeByClick(step) else { return }
        noteOwnerFinished(step)
        // A form field done: the next one straight away, without a new plan.
        if step.fill, let next = await nextFormField(after: step), token == generation, state.phase == .planning {
            state.restore(next, message: next.instruction)
            lastStep = next
            publish()
            armWatch()
            return
        }
        pendingCheck = (step, reacted, step.typeText != nil, true)
        publish()
        if state.phase == .planning { await planNext(generation: token) }
    }

    /// The answer to a question about the step being shown: where it is, then the
    /// step again. The presenter points at it again alongside.
    func currentStepExplanation() -> String {
        guard state.phase == .waiting, let step = state.step else { return state.message }
        let place = step.keyboard
            ? (step.typeText != nil ? "Type it where I'm pointing, in what's selected now." : "Press it here, in this window.")
            : "Right where I'm pointing."
        return place + " " + step.instruction
    }

    /// After a form field is filled, the next field of the planned list that is
    /// still on screen (found by its label) and still empty. Nil when none is
    /// left or the page changed; then the planner looks again.
    private func nextFormField(after done: GoWalkthroughStep) async -> GoWalkthroughStep? {
        guard done.fill, done.app == formApp, !formQueue.isEmpty, let finished = done.field else { return nil }
        if let index = formQueue.firstIndex(where: { Self.sameField($0.field, finished) }) {
            formQueue.removeFirst(index + 1)
        }
        let app = done.app
        let onScreen = await Task.detached { [fields] in fields(app) }.value
        while let entry = formQueue.first {
            formQueue.removeFirst()
            guard let field = onScreen.first(where: { Self.sameField($0, entry.field) }) else { continue }
            // Filled already (autofill, or done out of order): nothing to do there.
            let frame = field.frame
            let filled = await Task.detached { [fieldHasText] in fieldHasText(frame) }.value
            if filled { continue }
            var step = GoWalkthroughStep(instruction: entry.instruction, app: app, windowToken: done.windowToken,
                                         control: nil, menu: nil, expected: nil, field: field)
            step.fill = true
            step.windowName = done.windowName
            return step
        }
        return nil
    }

    /// The same form field on a later read: by name when it has one, else by
    /// where it sits (PDF and many web forms leave fields unnamed).
    nonisolated static func sameField(_ a: GoTextField, _ b: GoTextField) -> Bool {
        guard a.role == b.role else { return false }
        let nameA = a.label.trimmingCharacters(in: .whitespaces), nameB = b.label.trimmingCharacters(in: .whitespaces)
        if !nameA.isEmpty || !nameB.isEmpty { return nameA == nameB }
        return abs(a.frame.midX - b.frame.midX) <= 12 && abs(a.frame.midY - b.frame.midY) <= 12
    }

    /// An answer to the owner's question about the step being shown ("what's a
    /// routing number?", "do I need this one?"), from the planner with the step
    /// and the screen. The step itself stays. While a form is being filled in, no
    /// screenshot is taken, so the owner's details stay on the Mac.
    func answerAboutCurrentStep(_ question: String) async -> String? {
        guard state.phase == .waiting, let step = state.step, let goal = goals.activeGoal else { return nil }
        let token = generation
        guard let observation = try? await readObservation(menus: false, expectedApp: step.app, allowPartial: true) else { return nil }
        var catalog = GoObservation(app: observation.app, windowToken: observation.windowToken, windowName: observation.windowName,
                                    complete: observation.complete, controls: GoObservation.catalogControls(observation.controls))
        let app = observation.app
        catalog.fields = await Task.detached { [fields] in fields(app) }.value
        var context = GoPlanningContext(goal: goal, observation: catalog, verifiedSteps: Array(state.verifiedSteps.suffix(8)),
                                        catalogLimited: catalog.controls.count < observation.controls.count,
                                        earlierSteps: Self.earlierSteps(state.verifiedSteps, shownInFull: 8), notes: notes, checklist: checklist)
        context.recent = recent.map(\.line)
        context.ownerQuestion = String(question.prefix(300))
        context.currentStep = String((step.instruction + " (" + step.targetDescription + ")").prefix(300))
        if !step.fill, formQueue.isEmpty, let shot = await capture() { context.screenshotJPEG = shot.jpeg }
        guard let proposal = try? await planner(context), token == generation, state.step == step,
              proposal.kind == .answer || proposal.kind == .ask else { return nil }
        return proposal.instruction
    }

    /// The owner did the step Go handed them: carry on by itself after the next plan.
    private func noteOwnerFinished(_ step: GoWalkthroughStep) {
        guard let handed = handedBack, handed == step else { return }
        handedBack = nil
        resumeAfterPlan = true
    }

    /// The presenter finished the last step without seeing its result (a typing
    /// step whose field couldn't be read): only a changed screen counts now.
    func lastCompletionWasGuessed() {
        pendingCheck?.typedMatch = false
    }

    /// Waits until a cheap fingerprint of the app in front changes (see
    /// `GoScreenPulse`), or until `cap`, then gives it a moment to settle. The
    /// planning read that follows is the full one.
    private func waitForPulse(from baseline: Int, cap: Duration, after action: String) async -> Bool {
        let clock = ContinuousClock()
        let started = clock.now
        var reacted = false
        while clock.now - started < cap, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(40))
            if await Task.detached(operation: { [pulse] in pulse() }).value != baseline { reacted = true; break }
        }
        if reacted { try? await Task.sleep(for: .milliseconds(150)) }
        if logTransitions {
            let elapsed = clock.now - started
            let ms = Int(elapsed.components.seconds * 1000) + Int(elapsed.components.attoseconds / 1_000_000_000_000_000)
            MeasurementLogFile.appendJSONLine(["kind": "reaction", "time": Date().timeIntervalSince1970, "after": action,
                                               "ms": ms, "early": reacted, "check": "pulse"], toFileNamed: "go-walkthrough.log")
        }
        return reacted
    }

    /// Waits until the screen shows the app reacted (a different app, window,
    /// title or control list), or until `cap`.
    @discardableResult
    private func waitForReaction(from baseline: Int, cap: Duration, after action: String) async -> Bool {
        let clock = ContinuousClock()
        let started = clock.now
        var reacted = false
        while clock.now - started < cap, !Task.isCancelled {
            if let now = try? await readObservation(menus: false), now.contextHash != baseline { reacted = true; break }
            try? await Task.sleep(for: .milliseconds(40))
        }
        if logTransitions {
            let elapsed = clock.now - started
            let ms = Int(elapsed.components.seconds * 1000) + Int(elapsed.components.attoseconds / 1_000_000_000_000_000)
            MeasurementLogFile.appendJSONLine(["kind": "reaction", "time": Date().timeIntervalSince1970, "after": action,
                                               "ms": ms, "early": reacted], toFileNamed: "go-walkthrough.log")
        }
        return reacted
    }

    private func armWatch() {
        guard !suspended, !autopilot, state.phase == .waiting, let app = state.step?.app else { return }
        watch.start(app: app) { [weak self] in await self?.refresh() }
    }

    func refresh() async {
        guard !reading, !suspended, state.phase == .waiting, let step = state.step else { return }
        guard goalRevision == goals.state.revision, goals.activeGoal != nil else { stop(); return }
        guard frontmostApp() == step.app else { return }
        reading = true
        defer { reading = false }
        let token = generation
        guard let observation = try? await readObservation(menus: false, expectedApp: step.app),
              token == generation, !suspended, goalRevision == goals.state.revision else { return }
        if state.observe(observation, now: now()) {
            // Finished by its expected result appearing: seen working.
            if let done = state.verifiedSteps.last { pendingCheck = (done, true, false, true); noteOwnerFinished(done) }
            publish()
            if state.phase == .planning { await planNext(generation: token) }
        } else if state.noteOffTrack(observation, now: now()) {
            onOffTrack?(state)
        }
    }
}

/// Resumes a continuation once, with whichever answer arrives first.
private final class FirstAnswer: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<String?, Never>?
    init(_ continuation: CheckedContinuation<String?, Never>) { self.continuation = continuation }
    func give(_ value: String?) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: value)
    }
}
