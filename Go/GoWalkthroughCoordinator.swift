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
    /// The planner's working notes for the current goal (what it saw on screens
    /// that are no longer in view). Memory only; cleared with the goal.
    private(set) var notes: [String] = []
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
         logTransitions: Bool = true) {
        self.goals = goals; self.answer = answer; self.planner = planner; self.capture = capture
        self.frontmostApp = frontmostApp; self.now = now; self.pulse = pulse
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
    private func frontOwnersApp() async {
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == Bundle.main.bundleIdentifier,
              let app = (lastOwnerApp.flatMap { $0.isTerminated ? nil : $0 }) ?? Self.appOwningFrontWindow() else { return }
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
        guard let screen = try? await ScreenCaptureUtility.captureAllScreensAsJPEG().first,
              let jpeg = RealtimeOpenAppTool.downscaledJPEG(screen.imageData, maxPixelDimension: 1280),
              jpeg.count <= 700_000 else { return nil }
        return (jpeg.base64EncodedString(), GoFrame(screen.displayFrame))
    }

    func start() async -> [String: Any] {
        stop()
        guard goals.activeGoal != nil else { return ["ok": false, "message": "Tell me your goal first."] }
        state = GoWalkthroughState(); notes = []; checklist = []
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
        }
        generation = UUID()
        watch.stop()
        if state.phase == .done { publish(); return status() }
        await planNext(generation: generation)
        return status()
    }

    func stop() {
        clickedWhileSuspended = nil
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
                "askSource": state.phase == .needsInput ? (askSource ?? "planner") : NSNull()], toFileNamed: "go-walkthrough.log")
        }
        onChange?(state)
    }

    /// `allowPartial`: planning may use a read that hit the walk's size or time
    /// limits (very large interfaces); checking that a step happened never does.
    /// How long the last planning read spent on the element walk and on the
    /// rest (menus, fields, Dock and menu-bar icons), for the timing log.
    private var lastReadSplit: (walkMs: Int, extrasMs: Int)?

    private func readObservation(menus: Bool, expectedApp: String? = nil, allowPartial: Bool = false) async throws -> GoObservation {
        let startedAt = ProcessInfo.processInfo.systemUptime
        var request: [String: Any] = ["verb": "snapshot"]
        if let expectedApp { request["expectApp"] = expectedApp }
        let line = String(decoding: try JSONSerialization.data(withJSONObject: request), as: UTF8.self)
        let answer = self.answer
        let response = await Task.detached { answer(line) }.value
        guard var observation = GoObservation.decode(RealtimeOpenAppTool.harnessResponseObject(response)),
              observation.complete || allowPartial else {
            throw GoVoiceFailure(kind: "walkthrough:unreadableInterface")
        }
        let walkedAt = ProcessInfo.processInfo.systemUptime
        // Planning only: labels of typeable fields, never their contents. Read
        // alongside the menu bar rather than after it.
        let fieldsApp = observation.app
        let fieldsTask: Task<[GoTextField], Never>? = menus ? Task.detached { GoTextFields.list(app: fieldsApp) } : nil
        let systemTask: Task<[GoSystemControl], Never>? = menus ? Task.detached { GoSystemControls.current() } : nil
        if menus {
            let menuLine = String(decoding: try JSONSerialization.data(withJSONObject: ["verb": "menus", "expectApp": observation.app]), as: UTF8.self)
            let menuResponse = RealtimeOpenAppTool.harnessResponseObject(await Task.detached { answer(menuLine) }.value)
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
        guard state.verifiedSteps.count < 50 else { state.ask("Let's check the goal before continuing."); publish(); return }
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
            let shot = await captureTask.value
            let capturedAt = ProcessInfo.processInfo.systemUptime
            observation.screenFrame = shot?.frame
            guard token == generation, goalRevision == goals.state.revision else { return }
            let catalog = GoObservation(app: observation.app, windowToken: observation.windowToken, windowName: observation.windowName,
                                        complete: observation.complete, controls: GoObservation.catalogControls(observation.controls),
                                        menus: Array(observation.menus.prefix(180)), fields: observation.fields,
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
            // A partial read (a very large interface) leans on the screenshot too.
            if sparse || afterReveal || !observation.complete || visualApps.contains(observation.app) { context.screenshotJPEG = shot?.jpeg }
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
                if proposal.needScreen == true || proposal.kind == .answer || proposal.kind == .reveal || proposal.kind == .launch
                    || proposal.targetID == "screen" {
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
                    "checklistChanged": proposal.checklist != nil], toFileNamed: "go-walkthrough.log")
            }
            guard token == generation, goalRevision == goals.state.revision, !Task.isCancelled else { return }
            // Launch steps name an app, and screen steps a box on the screenshot
            // (validated in accept); every other target must be an observed ID.
            if proposal.kind == .step || proposal.kind == .point, proposal.targetID != "screen", proposal.targetID != "keyboard",
               !catalog.controls.contains(where: { $0.id == proposal.targetID }) && !catalog.menus.contains(where: { $0.id == proposal.targetID })
               && !catalog.fields.contains(where: { $0.id == proposal.targetID })
               && !catalog.systemControls.contains(where: { $0.id == proposal.targetID }) {
                askSource = "targetNotObserved"
                state.ask("The proposed control wasn't in the observed interface."); publish(); return
            }
            // Recheck the same interface after the network call. The proposal's
            // IDs belong to the earlier catalogue and must not be reinterpreted.
            let fresh = try await readObservation(menus: false, expectedApp: observation.app, allowPartial: true)
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
            if let item = state.boxLandedOn {
                // The box fell on a Dock or menu-bar item the plan didn't mean: say so
                // to the planner and look again, rather than act on another app.
                let place = item.kind == "dockItem" ? "the Dock item" : "the menu-bar icon"
                remember("A screen box fell on \(place) \u{201C}\(item.name)\u{201D}, which was not the target; "
                         + "box the target inside the app's own window.")
                askSource = "boxOnSystemItem"
                return await replan(token, prefix: prefix, attempt: attempt,
                                    reason: "I couldn't pin down where that is. Can you point me to it?")
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
        } catch {
            guard token == generation else { return }
            // Right after a click the app is often mid-change; read again before giving up.
            await replan(token, prefix: prefix, attempt: attempt,
                         reason: "I couldn't read or plan this step reliably. Please try again from the relevant window.")
        }
    }

    /// The owner really is somewhere else and cannot be pointed back:
    /// plan from here, falling back to the pending step if that fails.
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
            askSource = "readOrPlanFailed"; state.ask(reason); publish(); return
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
            generation = UUID(); state = GoWalkthroughState(); notes = []; checklist = []; goalRevision = goals.state.revision; goalID = goals.activeGoal?.id
        }
        // Resuming after Go's own question ("want me to go ahead?") performs that
        // step. Taking over a step Go was showing the owner looks again first: they
        // may have done it, or half of it (text typed), and repeating it would
        // click twice or type the text on top of theirs.
        let resuming = pausedForQuestion
        autopilot = true
        pausedForQuestion = false
        watch.stop()
        suspended = false
        if state.phase != .waiting || !resuming { await planNext(generation: generation) }
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
                    state.restore(again, message: "I tried that, but it didn't take. Can you do this one? " + again.instruction)
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
            case .retryable(let reason), .blocked(let reason):
                autopilot = false
                askSource = "autopilotStopped"
                state.restore(step, message: "I couldn't do this one: \(reason). Can you do it? " + step.instruction)
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
        pendingCheck = (step, reacted, step.typeText != nil, true)
        publish()
        if state.phase == .planning { await planNext(generation: token) }
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
            if let done = state.verifiedSteps.last { pendingCheck = (done, true, false, true) }
            publish()
            if state.phase == .planning { await planNext(generation: token) }
        } else if state.noteOffTrack(observation, now: now()) {
            onOffTrack?(state)
        }
    }
}
