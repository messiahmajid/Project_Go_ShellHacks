import AppKit
import Foundation

/// Latest-message presentation. It never sends an action to the target app.
@MainActor
final class GoGuidePresenter {
    typealias Resolve = @MainActor (GoWalkthroughStep) async -> CGRect?
    private let resolve: Resolve
    private let speak: @MainActor (String) async throws -> Void
    private let stopSpeech: @MainActor () -> Void
    private let showText: @MainActor (String?) -> Void
    private let point: @MainActor (CGRect?, String) -> Void
    private let isCurrent: @MainActor (GoWalkthroughState) -> Bool
    private let stillWaiting: @MainActor (GoWalkthroughStep) -> Bool
    private let targetClicked: @MainActor (GoWalkthroughStep) -> Void
    /// Where the step's target is right now (nil when it is not on screen). No logging.
    private let locate: Resolve?
    /// Moves or hides the highlight without flying the cursor again.
    private let highlight: @MainActor (CGRect?) -> Void
    /// The target's current on-screen frame, kept up to date while the step waits.
    private var trackedRect: CGRect?
    /// Where the target was when the tracker last hid it, and when.
    private var lastSeen: (rect: CGRect, at: Date)?
    private var recentlySeenRect: CGRect? {
        guard let lastSeen, Date().timeIntervalSince(lastSeen.at) < 3 else { return nil }
        return lastSeen.rect
    }
    private var task: Task<Void, Never>?
    private var speechTask: Task<Void, Never>?
    private var keyMonitor: Any?
    private var generation = UUID()
    private var clickMonitor: Any?
    private var lastNudge: Date = .distantPast
    private var phrases = GoPhrases()

    init(resolve: @escaping Resolve, speak: @escaping @MainActor (String) async throws -> Void,
         stopSpeech: @escaping @MainActor () -> Void, showText: @escaping @MainActor (String?) -> Void,
         point: @escaping @MainActor (CGRect?, String) -> Void,
         isCurrent: @escaping @MainActor (GoWalkthroughState) -> Bool = { _ in true },
         stillWaiting: @escaping @MainActor (GoWalkthroughStep) -> Bool = { _ in false },
         targetClicked: @escaping @MainActor (GoWalkthroughStep) -> Void = { _ in },
         locate: Resolve? = nil, highlight: @escaping @MainActor (CGRect?) -> Void = { _ in }) {
        self.resolve = resolve; self.speak = speak; self.stopSpeech = stopSpeech
        self.showText = showText; self.point = point
        self.isCurrent = isCurrent
        self.stillWaiting = stillWaiting
        self.targetClicked = targetClicked
        self.locate = locate
        self.highlight = highlight
    }

    func cancel() {
        generation = UUID(); task?.cancel(); task = nil
        speechTask?.cancel(); speechTask = nil
        trackedRect = nil
        lastSeen = nil
        removeClickMonitor()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        activationObserver = nil
        if let activityMonitor { NSEvent.removeMonitor(activityMonitor) }
        activityMonitor = nil
        stopSpeech(); showText(nil); point(nil, "")
    }

    private func removeClickMonitor() {
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
    }

    /// A click in the step's app that lands away from the pointed control, and
    /// leaves the step unfinished once the UI settles, gets a short correction
    /// and the pointer again. Structural wrong turns are the coordinator's job.
    private func watchClicks(around rect: CGRect, state: GoWalkthroughState, isFinal: Bool = true) {
        removeClickMonitor()
        guard let step = state.step else { return }
        let token = generation
        trackedRect = rect
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            let location = NSEvent.mouseLocation
            Task { @MainActor [weak self] in
                // The target as it is now; while it is off screen, clicks are not judged.
                // The target as it is now, or where it was a moment ago if the tracker just
                // hid it: a click there still counts, and the next read decides what follows.
                guard let self, token == self.generation,
                      let target = (self.trackedRect ?? self.recentlySeenRect)?.insetBy(dx: -12, dy: -12) else { return }
                if target.contains(location) {
                    // A click on a menu title only opens the menu; the item inside finishes the step.
                    if isFinal, GoActiveApp.isActive(step.app) || step.menu != nil {
                        self.removeClickMonitor()
                        // Stops menu following and nudges; speech and the bubble stay until the next step.
                        self.generation = UUID()
                        self.targetClicked(step)
                    }
                    return
                }
                guard
                      GoActiveApp.isActive(step.app),
                      Date().timeIntervalSince(self.lastNudge) > 4 else { return }
                try? await Task.sleep(for: .milliseconds(2500))
                guard token == self.generation, self.stillWaiting(step), self.isCurrent(state) else { return }
                self.lastNudge = Date()
                await self.nudge(state, step: step)
            }
        }
    }

    /// A reveal step ("Scroll down to Signature") finishes when the owner has
    /// scrolled, clicked or used the keyboard in the step's app and then paused,
    /// so Go looks again without being asked. Only that activity happened is used.
    private var activityMonitor: Any?
    private func watchActivity(_ step: GoWalkthroughStep, token: UUID) {
        if let activityMonitor { NSEvent.removeMonitor(activityMonitor) }
        var lastActivity: Date?
        activityMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.scrollWheel, .leftMouseDown, .keyDown]) { _ in
            lastActivity = Date()
        }
        Task { [weak self] in
            while let self, token == self.generation, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(150))
                guard token == self.generation, self.stillWaiting(step) else { return }
                guard let last = lastActivity, Date().timeIntervalSince(last) > 0.6,
                      GoActiveApp.isActive(step.app) else { continue }
                if let monitor = self.activityMonitor { NSEvent.removeMonitor(monitor) }
                self.activityMonitor = nil
                self.generation = UUID()
                self.targetClicked(step)
                return
            }
        }
    }

    /// Keeps the highlight on the target while the step waits: it moves with the
    /// target, hides while the target is off screen, and returns with it.
    private func trackTarget(_ step: GoWalkthroughStep, from start: CGRect, token: UUID) {
        guard let locate else { return }
        // Fixed-position targets (fields, screenshot boxes) also remember what sat
        // under them, so a scroll or a replaced view hides the stale highlight.
        let anchored = step.control == nil
        Task { [weak self] in
            var shown: CGRect? = start
            let center = CGPoint(x: start.midX, y: start.midY)
            let anchor = anchored ? await Task.detached { GoScreenClick.fingerprint(at: center) }.value : nil
            while let self, token == self.generation, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(450))
                guard token == self.generation, self.stillWaiting(step) else { return }
                var now = await locate(step)
                if let anchor, let rect = now {
                    let point = CGPoint(x: rect.midX, y: rect.midY)
                    // Only a clear, different answer means the content changed; no answer
                    // (or Go's own overlay) says nothing either way.
                    if let seen = await Task.detached(operation: { GoScreenClick.fingerprint(at: point) }).value, seen != anchor { now = nil }
                }
                guard token == self.generation else { return }
                if let now, let before = shown, abs(now.minX - before.minX) < 2, abs(now.minY - before.minY) < 2,
                   abs(now.width - before.width) < 2, abs(now.height - before.height) < 2 { continue }
                if now == nil && shown == nil { continue }
                shown = now
                if now == nil, let previous = self.trackedRect { self.lastSeen = (previous, Date()) }
                self.trackedRect = now
                self.highlight(now)
            }
        }
    }

    /// A typing step completes once the field holds the text. The contents are
    /// compared here and discarded; they are never logged or sent.
    private func followTyping(_ text: String, in rect: CGRect, step: GoWalkthroughStep, needsReturn: Bool, token: UUID) {
        // Only whether Return was pressed is recorded; no other keys are looked at.
        var returnPressed = false
        if needsReturn {
            keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
                if event.keyCode == 36 || event.keyCode == 76 { returnPressed = true }
            }
        }
        let app = step.app
        Task { [weak self] in
            var matchedOnce = false
            var initial: String??
            while let self, token == self.generation, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(350))
                guard token == self.generation, self.stillWaiting(step) else { return }
                let (contents, focusHere) = await Task.detached { () -> (String?, Bool) in
                    (GoTextFields.contents(at: rect), GoTextFields.focusFrame(app: app).map { $0.intersects(rect) } ?? false)
                }.value
                if initial == nil { initial = .some(contents) }
                let matched = GoTextFields.matches(contents, typeText: text)
                let fieldGone = contents == nil
                // Two matching reads in a row, so a half-typed word is not taken as done;
                // a field that closed right after matching (Return) also counts.
                // After Return the next plan reads the real result, so a fast typist is never left waiting.
                var finished = needsReturn ? (returnPressed && (matched || matchedOnce || fieldGone))
                                           : (matchedOnce && (matched || fieldGone))
                // The owner typed something of their own (their real name, not the
                // example) and moved on: that is their answer. Done, without praise.
                let changedByOwner = contents.map { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } == true
                    && initial.map { $0 != contents } == true
                if !finished, !matched, changedByOwner, !focusHere {
                    finished = true
                    self.unconfirmedCompletion = step
                }
                if finished {
                    self.removeClickMonitor()
                    self.generation = UUID()
                    self.targetClicked(step)
                    return
                }
                matchedOnce = matched
            }
        }
    }

    /// While a menu step waits, move the pointer into the menu as the owner
    /// opens it (and back to the menu title if it closes). Speech runs alongside.
    private func followMenu(_ path: [String], step: GoWalkthroughStep, state: GoWalkthroughState,
                            from start: CGRect?, token: UUID) async {
        var current = start
        Task { [weak self] in
            while let self, token == self.generation, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(300))
                guard token == self.generation, self.stillWaiting(step) else { return }
                let app = step.app
                let found = await Task.detached { GoMenuPointer.target(app: app, path: path) }.value
                guard token == self.generation, let found, found.rect != current else { continue }
                current = found.rect
                self.point(found.rect, state.message)
                self.watchClicks(around: found.rect, state: state, isFinal: found.isLeaf)
            }
        }
    }

    /// How long a bubble stays after it is shown, or nil while a step is pending
    /// (the step's own text stays until the step changes).
    nonisolated static func bubbleLinger(for state: GoWalkthroughState) -> Double? {
        let words = Double(state.message.split(separator: " ").count)
        switch state.phase {
        case .done: return max(4, words * 0.4 + 2)
        case .needsInput: return max(20, words * 0.4 + 10)
        default: return nil
        }
    }

    /// Clicking the pointed target finishes the step, except a menu title (opens
    /// the menu) or a field (typing finishes it).
    nonisolated static func completesOnClick(_ step: GoWalkthroughStep) -> Bool {
        !step.reveal && !step.fill && step.typeText == nil && !step.opens && step.launchApp == nil && (step.menu.map { $0.path.count == 1 } ?? true)
    }

    /// A keyboard step finishes when the owner presses its keys in the step's
    /// app. A typing step finishes on what was typed, not on a pause: when the
    /// focused field can be read, only once it holds the text (seen twice, or
    /// on Return/Tab after it did); when it can't (a grid, a canvas), on
    /// Return/Tab or a long pause, and then without praise, since Go couldn't
    /// see the result. Which keys were typed is never recorded, only that typing
    /// or a commit key happened; field contents are compared locally.
    private func watchKeyboard(_ step: GoWalkthroughStep, token: UUID) {
        let combo = step.keys.flatMap(GoKeyCombo.parse)
        var lastTyped: Date?
        var committed = false
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let code = event.keyCode
            let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
            MainActor.assumeIsolated {
                guard let self, token == self.generation, self.stillWaiting(step), GoActiveApp.isActive(step.app) else { return }
                let pressedCombo = combo.map { code == $0.keyCode && Self.flags(flags) == Self.significant($0.flags) } ?? false
                // Keys alone: pressing them is the step.
                if step.typeText == nil {
                    if pressedCombo { self.generation = UUID(); self.targetClicked(step) }
                    return
                }
                // Text (then keys): the keys, or Return/Tab, only say "done" after typing.
                if pressedCombo || Self.commitKeyCodes.contains(code) { if lastTyped != nil { committed = true }; return }
                lastTyped = Date()
            }
        }
        guard let text = step.typeText else { return }
        let needsCommit = combo != nil
        let app = step.app
        Task { [weak self] in
            var matchedOnce = false
            while let self, token == self.generation, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(300))
                guard token == self.generation, self.stillWaiting(step) else { return }
                guard let typed = lastTyped else { continue }
                let contents = await Task.detached { GoTextFields.focusedContents(app: app) }.value
                guard token == self.generation, self.stillWaiting(step) else { return }
                let verdict = Self.typingVerdict(contents: contents, text: text, matchedBefore: matchedOnce, committed: committed,
                                                 needsCommit: needsCommit, quietSeconds: Date().timeIntervalSince(typed))
                switch verdict {
                case .finished(let confirmed):
                    self.unconfirmedCompletion = confirmed ? nil : step
                    self.generation = UUID(); self.targetClicked(step); return
                case .notYet(let matched):
                    matchedOnce = matched
                    // Return on text that doesn't match yet leaves the step open.
                    if contents != nil { committed = false }
                }
            }
        }
    }

    /// A form field the owner fills with their own details. Done once they have
    /// typed, the field isn't empty, and they move on (Tab, Return, or focus
    /// leaving the field). Only emptiness is checked, locally; the value is never
    /// read into Go's state, logged or sent. A field that can't be read (a
    /// password box) counts on moving on after typing, without praise.
    private func followFill(in rect: CGRect, step: GoWalkthroughStep, token: UUID) {
        var typed = false
        var committed = false
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
            let code = event.keyCode
            MainActor.assumeIsolated {
                guard GoActiveApp.isActive(step.app) else { return }
                if Self.commitKeyCodes.contains(code) { if typed { committed = true } } else { typed = true }
            }
        }
        let app = step.app
        Task { [weak self] in
            while let self, token == self.generation, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(300))
                guard token == self.generation, self.stillWaiting(step), typed else { continue }
                let (filled, stillHere) = await Task.detached { () -> (Bool?, Bool) in
                    let contents = GoTextFields.contents(at: rect)
                    let focus = GoTextFields.focusFrame(app: app)
                    return (contents.map { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty },
                            focus.map { $0.intersects(rect) } ?? false)
                }.value
                guard token == self.generation, self.stillWaiting(step) else { return }
                if Self.fillFinished(filled: filled, movedOn: committed || !stillHere) {
                    self.unconfirmedCompletion = filled == nil ? step : nil
                    self.removeClickMonitor()
                    self.generation = UUID()
                    self.targetClicked(step)
                    return
                }
            }
        }
    }

    /// `filled` is nil when the field can't be read (a password box).
    nonisolated static func fillFinished(filled: Bool?, movedOn: Bool) -> Bool {
        guard movedOn else { return false }
        return filled ?? true
    }

    /// Return, keypad Enter and Tab: the owner saying "that's it" in a field.
    nonisolated static let commitKeyCodes: Set<UInt16> = [36, 76, 48]

    enum TypingVerdict: Equatable {
        case finished(confirmed: Bool)
        case notYet(matched: Bool)
    }

    /// `contents` is nil when the focused field can't be read. `needsCommit`:
    /// the step ends with a key (Return, Tab, a shortcut), which must be pressed.
    nonisolated static func typingVerdict(contents: String?, text: String, matchedBefore: Bool, committed: Bool,
                                          needsCommit: Bool, quietSeconds: TimeInterval) -> TypingVerdict {
        guard let contents else {
            // Can't see the field. A commit key after a matching read is still a
            // confirmed finish (Return often closes the editor it was read from).
            if committed { return .finished(confirmed: matchedBefore) }
            // Only a long pause counts here: people stop mid-formula to look things up.
            return !needsCommit && quietSeconds > 10 ? .finished(confirmed: false) : .notYet(matched: false)
        }
        let matched = GoTextFields.matches(contents, typeText: text)
        if matched && (committed || (!needsCommit && matchedBefore)) { return .finished(confirmed: true) }
        return .notYet(matched: matched)
    }

    /// The step just finished on a guess (a typing step whose field couldn't be
    /// read): no praise for it. Cleared by whoever reads it.
    var unconfirmedCompletion: GoWalkthroughStep?

    nonisolated static func flags(_ flags: NSEvent.ModifierFlags) -> CGEventFlags {
        var result = CGEventFlags()
        if flags.contains(.command) { result.insert(.maskCommand) }
        if flags.contains(.shift) { result.insert(.maskShift) }
        if flags.contains(.option) { result.insert(.maskAlternate) }
        if flags.contains(.control) { result.insert(.maskControl) }
        return result
    }

    nonisolated static func significant(_ flags: CGEventFlags) -> CGEventFlags {
        flags.intersection([.maskCommand, .maskShift, .maskAlternate, .maskControl])
    }

    /// Launch and open steps finish when a different app comes to the front
    /// (the named app, or whichever app opened the item).
    private var activationObserver: Any?
    private func watchActivation(_ step: GoWalkthroughStep, token: UUID) {
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let activated = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated {
                guard let self, token == self.generation, self.stillWaiting(step), let activated,
                      Self.activationFinishes(step, activated: activated.bundleIdentifier, name: activated.localizedName) else { return }
                self.finishByActivation(step)
            }
        }
        // The app may already have come forward before the step was shown.
        if let front = NSWorkspace.shared.frontmostApplication,
           Self.activationFinishes(step, activated: front.bundleIdentifier, name: front.localizedName), step.launchApp != nil {
            finishByActivation(step)
        }
    }

    private func finishByActivation(_ step: GoWalkthroughStep) {
        if let observer = activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        activationObserver = nil
        generation = UUID()
        targetClicked(step)
    }

    /// Whether this app coming forward finishes a launch or open step: another
    /// app than the step's (and not Go), and for a launch, the app it named.
    nonisolated static func activationFinishes(_ step: GoWalkthroughStep, activated bundleIdentifier: String?, name: String?) -> Bool {
        guard let bundleIdentifier, bundleIdentifier != Bundle.main.bundleIdentifier, bundleIdentifier != step.app else { return false }
        guard let wanted = step.launchApp else { return true }
        let name = (name ?? "").lowercased(), target = wanted.lowercased()
        return !name.isEmpty && (name == target || name.contains(target) || target.contains(name)) || bundleIdentifier == wanted
    }

    /// The owner left the step's screen: say so and fly back to the step.
    /// False when the step can no longer be pointed at from here.
    func redirect(_ state: GoWalkthroughState) async -> Bool {
        guard let step = state.step else { return false }
        if Date().timeIntervalSince(lastNudge) < 4 { return true }
        guard await resolve(step) != nil, stillWaiting(step), isCurrent(state) else { return false }
        lastNudge = Date()
        await nudge(state, step: step)
        if let current = trackedRect { watchClicks(around: current, state: state, isFinal: Self.completesOnClick(step)) }
        return true
    }

    /// Points back at where the target is now, never at a stale spot.
    private func nudge(_ state: GoWalkthroughState, step: GoWalkthroughStep) async {
        let token = generation
        let fresh = await (locate ?? resolve)(step)
        guard token == generation else { return }
        let text = phrases.say(.offTrack) + " " + state.message
        stopSpeech()
        showText(text)
        if let fresh { trackedRect = fresh; point(fresh, text) } else { highlight(nil) }
        task = Task { [weak self] in
            guard let self, token == self.generation else { return }
            try? await self.speak(text)
        }
    }

    func present(_ state: GoWalkthroughState, spoken: Bool) {
        cancel()
        guard state.phase == .waiting || state.phase == .needsInput || state.phase == .done,
              !state.message.isEmpty else { return }
        let token = generation
        guard isCurrent(state) else {
            // The step belongs to another app: say so rather than stay silent.
            // Switching back to it shows the step again.
            if state.phase == .waiting, let app = state.step?.app,
               let name = NSRunningApplication.runningApplications(withBundleIdentifier: app).first?.localizedName {
                let text = "Switch back to \(name) to continue."
                showText(text)
                if spoken { speechTask = Task { [weak self] in
                    guard let self, token == self.generation else { return }
                    try? await self.speak(text)
                } }
            }
            return
        }
        showText(state.message)
        // Speech starts right away; pointing is resolved alongside it.
        if spoken {
            speechTask = Task { [weak self] in
                guard let self, token == self.generation, self.isCurrent(state) else { return }
                // Text remains available if the speech service fails.
                try? await self.speak(state.message)
            }
        }
        task = Task { [weak self] in
            guard let self else { return }
            if let step = state.step {
                if step.reveal { self.watchActivity(step, token: token) }
                if step.launchApp != nil || step.opens { self.watchActivation(step, token: token) }
                if step.keyboard { self.watchKeyboard(step, token: token) }
                let rect = await self.resolve(step)
                guard token == self.generation, !Task.isCancelled, self.isCurrent(state) else { return }
                self.point(rect, state.message)
                // Clicking into a field only focuses it; the typed text finishes that step.
                // Keyboard steps point at where typing lands; a click elsewhere isn't a wrong turn.
                // Moving to the next form field by clicking it isn't a wrong turn either.
                if let rect, !step.keyboard, !step.fill { self.watchClicks(around: rect, state: state, isFinal: Self.completesOnClick(step)) }
                if let rect, step.menu == nil, step.launchApp == nil { self.trackTarget(step, from: rect, token: token) }
                if let rect, let text = step.typeText {
                    self.followTyping(text, in: rect, step: step, needsReturn: step.pressReturn, token: token)
                }
                if let rect, step.fill { self.followFill(in: rect, step: step, token: token) }
                if let menu = step.menu { await self.followMenu(menu.path, step: step, state: state, from: rect, token: token) }
            }
            await self.speechTask?.value
            // Final messages (answers, done) clear shortly after; an open question
            // stays readable longer, then fades (Go still remembers it).
            if let linger = Self.bubbleLinger(for: state) {
                try? await Task.sleep(for: .seconds(linger))
                guard token == self.generation, !Task.isCancelled else { return }
                self.showText(nil)
            }
        }
    }

    /// Pointing is read-only, so it tolerates what verification must not: a
    /// partial AX read or a replaced window token. One unambiguous match by
    /// role and name (or by name alone if the role drifted) is still required.
    /// Every attempt is logged to go-grounding.log with the reason it failed.
    static func resolve(_ step: GoWalkthroughStep, answer: @escaping @Sendable (String) -> String, log: Bool = true) async -> CGRect? {
        let name = step.control?.name ?? step.menu?.path.first
        let role = step.control?.role ?? "AXMenuBarItem"
        var record: [String: Any] = ["kind": "grounding", "time": Date().timeIntervalSince1970, "app": step.app,
                                     "role": role, "nameLength": name?.count ?? 0, "isMenu": step.menu != nil]
        func finish(_ outcome: String, _ rect: CGRect? = nil) -> CGRect? {
            record["outcome"] = outcome
            if let rect { record["rect"] = ["x": rect.minX, "y": rect.minY, "w": rect.width, "h": rect.height] }
            if log { MeasurementLogFile.appendJSONLine(record, toFileNamed: "go-grounding.log") }
            return rect
        }
        if step.keyboard {
            // Point where the typing or keys will land (the selected cell, field or text).
            let app = step.app
            guard GoActiveApp.isActive(app), let rect = await Task.detached(operation: { GoTextFields.focusFrame(app: app) }).value
            else { return finish("keyboardStep") }
            return finish("pointedFocus", rect)
        }
        if let app = step.launchApp {
            // Point at the app's Dock icon when it has one; clicking it opens the app.
            let rect = await Task.detached { GoMenuPointer.dockIcon(named: app) }.value
            return rect.map { finish("pointedDock", $0) } ?? finish("launchNotInDock")
        }
        if let screenRect = step.screenRect { return finish("pointedScreen", screenRect.rect) }
        if let field = step.field {
            record["role"] = field.role
            guard GoActiveApp.isActive(step.app) else { return finish("otherAppFrontmost") }
            return finish("pointedField", field.frame)
        }
        guard let name else { return finish("noTargetName") }
        if let menu = step.menu {
            let path = menu.path, app = step.app
            let rect = await Task.detached { GoMenuPointer.frame(app: app, path: path) }.value
            guard GoActiveApp.isActive(step.app) else { return finish("otherAppFrontmost") }
            return rect.map { finish("pointedMenu", $0) } ?? finish("menuBarItemNotFound")
        }
        let snapshotLine = String(decoding: (try? JSONSerialization.data(withJSONObject:
            ["verb": "snapshot", "expectApp": step.app])) ?? Data(), as: UTF8.self)
        let snapshot = RealtimeOpenAppTool.harnessResponseObject(await Task.detached { answer(snapshotLine) }.value)
        guard !Task.isCancelled else { return nil }
        guard snapshot["ok"] as? Bool == true else { return finish("snapshotFailed:\(snapshot["error"] as? String ?? "-")") }
        guard snapshot["bundleIdentifier"] as? String == step.app else { return finish("otherAppFrontmost") }
        let window = snapshot["window"] as? [String: Any]
        record["sameWindow"] = window?["token"] as? String == step.windowToken
        record["partialRead"] = (snapshot["walkStopReasons"] as? [String])?.isEmpty == false || snapshot["incompleteReads"] as? Bool == true
        let elements = snapshot["elements"] as? [[String: Any]] ?? []
        record["elementCount"] = elements.count
        var matches = elements.filter { $0["role"] as? String == role && $0["name"] as? String == name }
        record["roleNameMatches"] = matches.count
        if matches.isEmpty {
            matches = elements.filter { $0["name"] as? String == name && $0["nameIsPlausibleLabel"] as? Bool == true }
            record["nameOnlyMatches"] = matches.count
        }
        guard !matches.isEmpty else { return finish("noMatch") }
        guard matches.count == 1 else { return finish("ambiguous") }
        guard let frame = matches[0]["frame"] as? [String: Any], let rect = rect(frame) else { return finish("noFrame") }
        if let bounds = window?["frame"] as? [String: Any], let windowRect = Self.rect(bounds),
           let reason = ActionSafetyKernel.unreachableFrameReason(rect, visibleBounds: windowRect) {
            record["unreachable"] = reason
            return finish("offScreen")
        }
        guard GoActiveApp.isActive(step.app) else { return finish("otherAppFrontmost") }
        return finish("pointed", rect)
    }

    /// The target's frame right now, or nil when it is not on screen. Controls are
    /// looked up again by role and name. Fields and screenshot targets have a fixed
    /// position inside their window: they follow a window move, and are hidden when
    /// the window is replaced, retitled or resized (its layout may have reflowed).
    static func locate(_ step: GoWalkthroughStep, answer: @escaping @Sendable (String) -> String) async -> CGRect? {
        if step.control != nil { return await resolve(step, answer: answer, log: false) }
        // Menu-bar icons and Dock items don't move with the app's window.
        if step.outsideWindow, let frame = step.screenRect?.rect { return GoActiveApp.isActive(step.app) ? frame : nil }
        guard let frame = step.screenRect?.rect ?? step.field?.frame,
              GoActiveApp.isActive(step.app) else { return nil }
        let line = String(decoding: (try? JSONSerialization.data(withJSONObject: ["verb": "snapshot", "expectApp": step.app])) ?? Data(), as: UTF8.self)
        let snapshot = RealtimeOpenAppTool.harnessResponseObject(await Task.detached { answer(line) }.value)
        guard snapshot["ok"] as? Bool == true, let window = snapshot["window"] as? [String: Any],
              window["token"] as? String == step.windowToken,
              step.windowName.isEmpty || window["name"] as? String == step.windowName else { return nil }
        let now = (window["frame"] as? [String: Any]).flatMap(rect)
        return followWindow(frame, planned: step.windowFrame?.rect, now: now)
    }

    /// A fixed-position frame after its window moved: shifted with a same-size
    /// window, dropped when the window was resized, unchanged when either is unknown.
    nonisolated static func followWindow(_ frame: CGRect, planned: CGRect?, now: CGRect?) -> CGRect? {
        guard let planned, let now else { return frame }
        guard abs(planned.width - now.width) < 2, abs(planned.height - now.height) < 2 else { return nil }
        return frame.offsetBy(dx: now.minX - planned.minX, dy: now.minY - planned.minY)
    }

    nonisolated static func rect(_ object: [String: Any]) -> CGRect? {
        guard let x = object["x"] as? Double, let y = object["y"] as? Double,
              let w = object["w"] as? Double, let h = object["h"] as? Double,
              [x, y, w, h].allSatisfy(\.isFinite), w > 0, h > 0 else { return nil }
        return CGRect(x: x, y: y, width: w, height: h)
    }
}
