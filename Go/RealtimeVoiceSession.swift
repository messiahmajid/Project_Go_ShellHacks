//
//  RealtimeVoiceSession.swift
//  Go
//
//  Push-to-talk voice. Key-down opens the mic and captures the screen; key-up
//  ends the input. Gemini Live handles the conversation and tool calls, and
//  complete reply sentences are spoken by ElevenLabs as they arrive. Each turn
//  appends one line of counts and timings (never words) to voice-live.log.
//

import AppKit
import AVFoundation
import Foundation

@MainActor
final class RealtimeVoiceSession {
    private let harnessAnswer: @Sendable (String) -> String
    private let speechClient: ElevenLabsTTSClient
    let goalStore = GoGoalStore()
    let routines = GoRoutineStore()
    /// The routine just saved or used: what "run it" refers to.
    private var recentRoutine: String?
    private(set) lazy var walkthrough: GoWalkthroughCoordinator = {
        let coordinator = GoWalkthroughCoordinator(goals: goalStore, answer: harnessAnswer)
        coordinator.onChange = { [weak self] state in
            guard let self, self.liveTurn == nil else { return }
            // While Go acts, it shows each step and speaks only questions and the finish.
            self.guide.present(state, spoken: !(self.walkthrough.autopilot && state.phase == .waiting))
            self.onStateChange?(state.phase == .planning ? .processing : .idle)
            // The notch shows Go working out the next step between voice turns.
            // A step about to be spoken goes straight from thinking to speaking.
            let spokenNext = state.phase == .waiting && !self.walkthrough.autopilot
            if state.phase == .planning { GoNotch.shared.handle(.planningStarted) }
            else if !spokenNext { GoNotch.shared.handle(.planningFinished) }
            if state.verifiedSteps.count < self.tickedSteps { self.tickedSteps = state.verifiedSteps.count }
            if state.phase == .planning {
                // A soft tick the moment Go registers the owner's step, so the wait for
                // the next one isn't silent. (Scrolling to look isn't a finished step.)
                if state.verifiedSteps.count > self.tickedSteps, !self.walkthrough.autopilot,
                   state.verifiedSteps.last?.reveal != true {
                    self.playTick(.release)
                }
                self.tickedSteps = state.verifiedSteps.count
                // No praise yet: the next plan checks the finished step against the
                // screen and says "nice" (or "not quite yet") with the next step.
                // A typing step finished without reading its field is reported, so
                // only a visible change can earn praise.
                if let guessed = self.guide.unconfirmedCompletion, guessed == state.verifiedSteps.last {
                    self.walkthrough.lastCompletionWasGuessed()
                }
                self.guide.unconfirmedCompletion = nil
                self.onGuideText?(self.phrases.say(.thinking))
            }
        }
        // The owner did the step Go couldn't: Go carries on by itself.
        coordinator.onResumeAutopilot = { [weak self] in
            guard let self, self.liveTurn == nil else { return }
            self.startAutopilot()
        }
        coordinator.onOffTrack = { [weak self] state in
            guard let self, self.liveTurn == nil else { return }
            Task {
                if await !self.guide.redirect(state) { await self.walkthrough.replanFromHere() }
            }
        }
        return coordinator
    }()
    private var phrases = GoPhrases()
    /// Finished steps already acknowledged with a tick.
    private var tickedSteps = 0
    /// Go asked "delete all your routines?" and waits for the owner's yes.
    private var pendingDeleteAllRoutines = false
    /// Guide text goes in the cursor's bubble.
    var onGuideText: ((String?) -> Void)?
    var onGuidePoint: ((CGRect?, String) -> Void)?
    var onGuideHighlight: ((CGRect?) -> Void)?
    /// Go is acting on its own (do it for me, routine replay): true at the start, false at the end.
    var onAutopilotChanged: ((Bool) -> Void)?
    /// Returns once the pointer has landed on the current step's target.
    var onAwaitPointer: (() async -> Void)?
    private lazy var guide = GoGuidePresenter(
        resolve: { [weak self] step in
            guard let self else { return nil }
            return await GoGuidePresenter.resolve(step, answer: self.harnessAnswer)
        }, speak: { [weak self] text in
            guard let self else { return }
            try await self.speechClient.speakText(text)
        }, stopSpeech: { [weak self] in self?.speechClient.stopPlayback() },
        showText: { [weak self] text in
            guard let self else { return }
            self.onGuideText?(text)
        }, point: { [weak self] rect, text in self?.onGuidePoint?(rect, text) },
        isCurrent: { state in state.app == nil || state.app.map(GoActiveApp.isActive) == true },
        stillWaiting: { [weak self] step in
            guard let state = self?.walkthrough.state else { return false }
            return state.phase == .waiting && state.step == step
        }, targetClicked: { [weak self] step in
            guard let self else { return }
            Task { await self.walkthrough.targetClicked(step) }
        }, locate: { [weak self] step in
            guard let self else { return nil }
            return await GoGuidePresenter.locate(step, answer: self.harnessAnswer)
        }, highlight: { [weak self] rect in self?.onGuideHighlight?(rect) })
    private let errorSpeech = AVSpeechSynthesizer()
    private var connection: RealtimeVoiceConnection?
    private var connectTask: Task<RealtimeVoiceConnection, Error>?

    private let micEngine = AVAudioEngine()
    private var audioContinuation: AsyncStream<Data>.Continuation?
    private var turnTask: Task<Void, Never>?
    /// The turn whose log line is not yet written.
    private var liveTurn: LiveTurn?

    private final class LiveTurn {
        var line: RealtimeLiveTurnLine
        let pressedUptime: TimeInterval
        var releasedUptime: TimeInterval?
        var speechRequestedUptime: TimeInterval?
        var speechStartedUptime: TimeInterval?
        var speechBuffer = GoSpeechBuffer()
        var speechTasks: [Task<Void, Error>] = []
        /// The model's reply so far, shown in the bubble as it is spoken.
        var shownReply = ""
        /// The goal's revision when the key went down, to notice the model saving one.
        var goalRevisionAtPress = 0
        var marks: RealtimeTurnMarks?
        init(line: RealtimeLiveTurnLine, pressedUptime: TimeInterval) {
            self.line = line
            self.pressedUptime = pressedUptime
        }
    }

    static let liveLogFileName = "voice-live.log"
    /// A tool call may wait on a 60 s confirmation.
    static let turnTimeoutSeconds: Double = 90
    private var uptime: TimeInterval { ProcessInfo.processInfo.systemUptime }

    private let playbackEngine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let playbackFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: Double(GoVoiceService.outputSampleRate), channels: 1, interleaved: false
    )!

    /// Press and release ticks, on their own player node.
    private let tickNode = AVAudioPlayerNode()
    private let tickFormat = AVAudioFormat(standardFormatWithSampleRate: GoNotchTick.sampleRate, channels: 1)!
    private lazy var tickBuffers: [GoNotchTick: AVAudioPCMBuffer] = Dictionary(
        uniqueKeysWithValues: GoNotchTick.allCases.compactMap { tick in tick.buffer(format: tickFormat).map { (tick, $0) } })

    /// listening, processing, responding, then idle.
    var onStateChange: ((GoVoiceState) -> Void)?

    init(harnessAnswer: @escaping @Sendable (String) -> String, speechClient: ElevenLabsTTSClient) {
        self.harnessAnswer = harnessAnswer
        self.speechClient = speechClient
        playbackEngine.attach(playerNode)
        playbackEngine.connect(playerNode, to: playbackEngine.mainMixerNode, format: playbackFormat)
        // The guide belongs to one app: hide it when the user leaves, restore on return.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.frontmostAppChanged() }
        }
        playbackEngine.attach(tickNode)
        playbackEngine.connect(tickNode, to: playbackEngine.mainMixerNode, format: tickFormat)
    }

    // MARK: Connection

    /// Setup takes about 2 s, so it happens at launch and after each turn.
    func prewarm() {
        Task { _ = try? await readyConnection() }
    }

    /// Reconnects lazily when the server closed the session.
    private func readyConnection() async throws -> RealtimeVoiceConnection {
        if let connection, connection.isOpen { return connection }
        if connectTask == nil {
            connection?.close()
            connection = nil
            let harnessAnswer = self.harnessAnswer
            connectTask = Task { @MainActor in
                let newConnection = RealtimeVoiceConnection(harnessAnswer: harnessAnswer, goalStore: goalStore, walkthrough: walkthrough)
                newConnection.drivesSpeechIndicators = false
                try await newConnection.connect()
                return newConnection
            }
        }
        let task = connectTask!
        do {
            let readyConnection = try await task.value
            if connectTask == task { connectTask = nil }
            wire(readyConnection)
            connection = readyConnection
            return readyConnection
        } catch {
            if connectTask == task { connectTask = nil }
            throw error
        }
    }

    private func wire(_ connection: RealtimeVoiceConnection) {
        // Gemini's own audio is received but never played.
        connection.onAudio = nil
        connection.onTranscript = { [weak self] text, marks in
            guard let self, let liveTurn = self.liveTurn, liveTurn.marks === marks, marks.finishedUptime == nil,
                  marks.walkthroughReply == nil else { return }
            for sentence in liveTurn.speechBuffer.append(text) {
                self.queueSpeech(sentence, for: liveTurn)
                self.showReply(sentence, in: liveTurn)
            }
        }
        connection.onWalkthroughInstruction = { [weak self] instruction, marks in
            guard let self, let turn = self.liveTurn, turn.marks === marks else { return }
            self.cancelQueuedSpeech()
            turn.speechTasks.removeAll()
            turn.speechBuffer = GoSpeechBuffer()
            self.guide.present(self.walkthrough.state, spoken: false)
            self.onStateChange?(.idle)
            self.queueSpeech(instruction, for: turn)
        }
        // Routine requests the local check didn't recognise, routed by the model:
        // handled exactly like the local ones, and spoken by Go.
        connection.onRoutineRequest = { [weak self] request, heard, marks in
            guard let self, let turn = self.liveTurn, turn.marks === marks,
                  let intent = request.intent(names: self.routines.routines.map(\.name)) else { return false }
            if case .list = intent {} else if heard == nil { return false }
            guard let text = await self.handleRoutine(intent, heard: heard ?? "", turn: turn),
                  self.liveTurn === turn else { return false }
            marks.goHandlesTurn = true
            marks.walkthroughReply = text
            self.cancelQueuedSpeech(); turn.speechTasks.removeAll(); turn.speechBuffer = GoSpeechBuffer()
            if self.walkthrough.state.phase != .waiting { self.onGuideText?(text) }
            self.onStateChange?(.idle)
            self.queueSpeech(text, for: turn)
            return true
        }
        connection.onTurnFinished = { [weak self] in
            self?.prewarm()
        }
        connection.onClosed = { [weak self, weak connection] in
            if let self, self.connection === connection { self.connection = nil }
        }
    }

    /// Serial playback, so later sentences arrive while the first is spoken. A new
    /// press cancels the queue.
    private func queueSpeech(_ sentence: String, for turn: LiveTurn) {
        let previous = turn.speechTasks.last
        let task = Task { [weak self] in
            try await previous?.value
            try Task.checkCancellation()
            guard let self, self.liveTurn === turn else { throw CancellationError() }
            if turn.speechRequestedUptime == nil { turn.speechRequestedUptime = self.uptime }
            try await self.speechClient.speakText(sentence)
            try Task.checkCancellation()
            guard self.liveTurn === turn else { throw CancellationError() }
            if turn.speechStartedUptime == nil { turn.speechStartedUptime = self.uptime }
            self.onStateChange?(turn.marks?.walkthroughReply == nil ? .responding : .idle)
            if turn.marks?.toolCalls.isEmpty == true { GoNotch.shared.handle(.firstAudioWithoutTool) }
            while self.speechClient.isPlaying {
                try await Task.sleep(nanoseconds: 50_000_000)
            }
        }
        turn.speechTasks.append(task)
    }

    /// While Go reads the screen and plans, a short spoken cue if that takes more
    /// than a moment, so a slow first step isn't silence. Fast plans say nothing
    /// extra. Cancel it once the real reply is ready.
    /// `cue` is the text already shown, so the bubble and the voice match.
    private func acknowledgeIfSlow(_ turn: LiveTurn, saying cue: String) -> Task<Void, Never> {
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1100))
            guard !Task.isCancelled, let self, self.liveTurn === turn, turn.speechTasks.isEmpty else { return }
            self.queueSpeech(cue, for: turn)
        }
    }

    /// Everything Go says is also shown: the model's reply, sentence by sentence.
    private func showReply(_ sentence: String, in turn: LiveTurn) {
        turn.shownReply = (turn.shownReply + " " + sentence).trimmingCharacters(in: .whitespaces)
        onGuideText?(turn.shownReply)
    }

    /// Clears a spoken reply's text once it has had time to be read, unless
    /// something newer is showing by then.
    private func clearReplyLater(_ shown: String) {
        let seconds = max(4, Double(shown.split(separator: " ").count) * 0.4 + 2)
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard let self, self.liveTurn == nil, self.walkthrough.state.phase != .waiting,
                  self.lastShownReply == shown else { return }
            self.onGuideText?(nil)
        }
        lastShownReply = shown
    }
    private var lastShownReply: String?

    private func cancelQueuedSpeech() {
        liveTurn?.speechTasks.forEach { $0.cancel() }
    }

    // MARK: Push-to-talk

    func pressed() {
        pendingAutopilot = false
        guide.cancel()
        walkthrough.suspend()
        // Menu-bar icons take a moment to read; start now, before any planning.
        Task.detached { GoSystemControls.prefetch() }
        // A new press silences whatever is still being said.
        cancelQueuedSpeech()
        writeLiveTurnLine(bargedIn: true)
        liveTurn = LiveTurn(
            line: RealtimeLiveTurnLine(stack: RealtimeVoiceConnection.logName, turnID: UUID().uuidString,
                                       sessionWasWarm: connection?.isOpen ?? false),
            pressedUptime: uptime)
        liveTurn?.goalRevisionAtPress = goalStore.state.revision
        stopPlayback()
        GoNotch.shared.handle(.hotkeyDown)
        playTick(.press)
        turnTask?.cancel()
        audioContinuation?.finish()

        let (audioStream, continuation) = AsyncStream<Data>.makeStream(bufferingPolicy: .unbounded)
        audioContinuation = continuation
        do {
            try startMic(targetSampleRate: GoVoiceService.inputSampleRate, continuation: continuation)
        } catch {
            print("❌ realtime: mic failed to start: \(error)")
            cancelQueuedSpeech()
            speechClient.stopPlayback()
            writeLiveTurnLine(errorKind: "micFailed")
            GoNotch.shared.handle(.hotkeyUp)
            GoNotch.shared.handle(.turnEnded)
            continuation.finish()
            onStateChange?(.idle)
            // Every way a turn ends hands the walkthrough back, or it stays paused.
            walkthrough.resume()
            return
        }
        onStateChange?(.listening)
        turnTask = Task { [weak self] in await self?.runTurn(audioStream) }
    }

    func released() {
        liveTurn?.releasedUptime = uptime
        stopMic()
        audioContinuation?.finish()
        audioContinuation = nil
        GoNotch.shared.handle(.hotkeyUp)
        playTick(.release)
        onStateChange?(.processing)
    }

    /// The mic already runs while this connects; its audio waits in the stream.
    private func runTurn(_ audioStream: AsyncStream<Data>) async {
        let liveTurn = self.liveTurn
        do {
            let screenshotTask = Task { @MainActor in
                try await ScreenCaptureUtility.captureAllScreensAsJPEG().first(where: \.isCursorScreen)
            }
            let setupStart = uptime
            let connection = try await readyConnection()
            if liveTurn?.line.sessionWasWarm == false { liveTurn?.line.sessionSetupMs = Self.milliseconds(from: setupStart, to: uptime) }
            if let screenshot = try? await screenshotTask.value {
                try await connection.sendScreenshot(screenshot.imageData)
            }
            try await connection.beginTurn()
            liveTurn?.marks = connection.turn
            for await pcmChunk in audioStream {
                try await connection.appendAudio(pcmChunk)
            }
            guard !Task.isCancelled else { return }
            try await connection.endTurn()
            let marks = connection.turn
            let guidance = Task { @MainActor [weak self] () -> Bool in
                guard let self, let liveTurn else { return false }
                return await self.routeGuidance(liveTurn, marks: marks)
            }
            // A request Go answers itself doesn't wait for the model's turn, which may
            // never speak again.
            if await guidance.value {
                _ = try? await connection.turn.finished.value(timeoutSeconds: 1.5, timeoutKind: "localGrace")
            } else {
                _ = try await connection.turn.finished.value(timeoutSeconds: Self.turnTimeoutSeconds, timeoutKind: "turnTimeout")
                await liveTurn?.marks?.waitForFreshLook()
            }
            guard !Task.isCancelled, self.liveTurn === liveTurn else { return }
            if let liveTurn, liveTurn.marks?.walkthroughReply == nil, let tail = liveTurn.speechBuffer.finish() {
                queueSpeech(tail, for: liveTurn)
                showReply(tail, in: liveTurn)
            }
            // The model can end a turn with no words and no tool call: say something
            // useful and record which case it was.
            var emptyReplyKind: String?
            let heardWords = (liveTurn?.marks?.heardText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if let liveTurn, liveTurn.speechTasks.isEmpty, !heardWords.isEmpty,
               goalStore.state.revision != liveTurn.goalRevisionAtPress, goalStore.activeGoal != nil {
                // The model saved the task as a goal and then said nothing: carry the
                // task on, the same way Go's own routing would have, instead of apologising.
                emptyReplyKind = "model:goalOnly"
                var text: String
                if GoVoiceActionPolicy.allowsActions(heard: heardWords) {
                    walkthrough.stop(); pendingAutopilot = true
                    text = phrases.say(.startForMe)
                } else {
                    _ = await walkthrough.start()
                    let state = walkthrough.state
                    text = state.message.isEmpty ? "I couldn't work out the next step here." : state.message
                    if state.phase == .waiting || state.phase == .needsInput { guide.present(state, spoken: false) }
                }
                guard self.liveTurn === liveTurn else { return }
                liveTurn.marks?.walkthroughReply = text
                onGuideText?(text)
                queueSpeech(text, for: liveTurn)
            }
            if let liveTurn, liveTurn.speechTasks.isEmpty {
                let heardNothing = (liveTurn.marks?.heardText ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                emptyReplyKind = heardNothing ? "noSpeechHeard" : "model:emptyReply"
                let text = heardNothing ? "I didn't catch that. Could you say it again?"
                                        : "Sorry, I didn't get an answer for that. Could you ask again?"
                queueSpeech(text, for: liveTurn)
                showReply(text, in: liveTurn)
            }
            guard let speechTask = liveTurn?.speechTasks.last else {
                throw GoVoiceFailure(kind: "speech:noReplyText")
            }
            do {
                try await speechTask.value
            } catch let error where error is CancellationError && !Task.isCancelled {
                // Newer speech replaced this reply, or speech was stopped on
                // purpose: the turn itself worked, so nothing is reported as failed.
            }
            guard self.liveTurn === liveTurn else { return }
            GoNotch.shared.handle(.turnEnded)
            onStateChange?(.idle)
            let guidedThisTurn = liveTurn?.marks?.walkthroughReply != nil
            writeLiveTurnLine(emptyReply: emptyReplyKind)
            walkthrough.resume()
            if pendingAutopilot { pendingAutopilot = false; startAutopilot() }
            // A side question hid the pointer; show the pending step again.
            if !guidedThisTurn, walkthrough.state.phase == .waiting { guide.present(walkthrough.state, spoken: false) }
            else if !guidedThisTurn, let shown = liveTurn?.shownReply, !shown.isEmpty { clearReplyLater(shown) }
        } catch {
            print("❌ realtime: turn failed: \(error)")
            pendingAutopilot = false
            // A barge-in already wrote this turn's line.
            guard self.liveTurn === liveTurn, liveTurn != nil else { return }
            cancelQueuedSpeech()
            speechClient.stopPlayback()
            writeLiveTurnLine(errorKind: (error as? GoVoiceFailure)?.kind ?? GoVoiceFailure.kind(for: error, stage: RealtimeVoiceConnection.logName))
            GoNotch.shared.handle(.turnEnded)
            // A failed turn still ends: the walkthrough resumes, and a click the owner
            // made during it (kept until now) counts.
            walkthrough.resume()
            if !Task.isCancelled {
                errorSpeech.speak(AVSpeechUtterance(string: "Go could not get a response. Please check the voice service connection."))
            }
            onStateChange?(.idle)
            prewarm()
        }
    }

    /// A new request replaces the goal; the old one stays in short-term memory
    /// so follow-ups like "open it" still make sense.
    /// Handles a routine request and returns what to say, or nil when the words
    /// weren't really about a routine (then the turn is handled as usual).
    private func handleRoutine(_ intent: GoRoutineIntent, heard: String, turn: LiveTurn) async -> String? {
        switch intent {
        case .save(let name, let explicit):
            let recentEnough = !walkthrough.state.verifiedSteps.isEmpty || (walkthrough.secondsSinceLastFinished ?? .infinity) < 600
            guard explicit || recentEnough else { return nil }
            guard let recorded = walkthrough.stepsToSave, !recorded.steps.isEmpty else {
                return "There's nothing to save yet. When we finish something together, say \u{201C}save this as\u{201D} and a name."
            }
            let steps = recorded.steps.map(GoRoutineStep.init)
            let goal = recorded.goal.isEmpty ? name : recorded.goal
            guard routines.save(name: name, goal: goal, steps: steps) else { return "I couldn't save that routine." }
            recentRoutine = routines.routine(named: name)?.name ?? name
            return "Saved \u{201C}\(name)\u{201D}. Say \u{201C}run \(name)\u{201D} and I'll do it, or \u{201C}walk me through \(name)\u{201D}."
        case .list:
            let names = routines.routines.map(\.name)
            guard let last = names.last else { return "You don't have any routines saved yet." }
            let joined = names.count == 1 ? last : names.dropLast().joined(separator: ", ") + " and " + last
            return names.count == 1 ? "You have one routine: \(joined)." : "Your routines are \(joined)."
        case .unknown(let name):
            let names = routines.routines.map(\.name)
            guard !names.isEmpty else { return "You don't have any routines saved yet." }
            return "I don't have a routine called \u{201C}\(name)\u{201D}. You have " + names.joined(separator: ", ") + "."
        case .deleteAll:
            let count = routines.routines.count
            guard count > 0 else { return "You don't have any routines saved." }
            // Deleting is the one thing Go always checks first.
            pendingDeleteAllRoutines = true
            return count == 1 ? "Delete your one routine, \u{201C}\(routines.routines[0].name)\u{201D}? Say yes to confirm."
                              : "Delete all \(count) routines? Say yes to confirm."
        case .delete(let name):
            return routines.delete(named: name) ? "Deleted \u{201C}\(name)\u{201D}." : "I couldn't delete that routine."
        case .run(let name), .walk(let name):
            guard let routine = routines.routine(named: name) else { return nil }
            recentRoutine = routine.name
            cancelQueuedSpeech(); turn.speechTasks.removeAll(); turn.speechBuffer = GoSpeechBuffer()
            rememberPreviousRequest()
            let task = String((routine.goal.isEmpty ? routine.name : routine.goal).prefix(80))
            let saved = goalStore.apply(GoGoalRequest(operation: .set, sourceQuote: heard, task: task), heard: heard,
                                        boundRevision: goalStore.state.revision)
            guard saved["ok"] as? Bool == true else { return "I couldn't start that routine. Please try again." }
            walkthrough.stop()
            walkthrough.useRoutine(routine)
            if case .run = intent {
                pendingAutopilot = true
                return phrases.say(.startForMe)
            }
            onGuideText?(phrases.say(.thinking))
            let result = await walkthrough.start()
            guard liveTurn === turn else { return "" }
            let state = walkthrough.state
            if result["ok"] as? Bool == false { return result["message"] as? String ?? "I couldn't start that routine." }
            if state.phase == .waiting || state.phase == .needsInput || state.phase == .done, !state.message.isEmpty {
                guide.present(state, spoken: false)
                return state.message
            }
            return "I couldn't find where to start \(routine.name) from here."
        }
    }

    private func rememberPreviousRequest() {
        if let previous = goalStore.activeGoal {
            walkthrough.remember("Earlier request: \u{201C}\(previous.lastInstruction)\u{201D}")
        }
    }

    /// Set by a "do it for me" turn; the run starts when the turn ends.
    private var pendingAutopilot = false

    private func startAutopilot() {
        let answer = harnessAnswer
        Task { [weak self] in
            guard let self else { return }
            self.onAutopilotChanged?(true)
            await self.walkthrough.runForMe(perform: { [weak self] step in
                await GoStepExecutor.perform(step, answer: answer) { [weak self] in
                    self?.onGuideText?("Please confirm in the Go panel.")
                    Task { try? await self?.speechClient.speakText("Please confirm that in the Go panel.") }
                }
            }, pointerSettled: { [weak self] in
                await self?.onAwaitPointer?()
            })
            self.onAutopilotChanged?(false)
        }
    }

    private func frontmostAppChanged() {
        let state = walkthrough.state
        guard liveTurn == nil, let app = state.app, state.phase == .waiting || state.phase == .needsInput,
              let frontmost = GoActiveApp.bundleIdentifier else { return }
        // A step finished by switching apps (opening an app or a file) is completed
        // by the presenter's own watcher; hiding the guide here would cancel it.
        if state.phase == .waiting, let step = state.step, step.launchApp != nil || step.opens, frontmost != app { return }
        if frontmost == app { guide.present(state, spoken: false) } else { guide.cancel() }
    }

    /// Guidance requests never depend on the model choosing a tool: Go saves
    /// the goal, plans one step, and speaks only that step.
    private func routeGuidance(_ turn: LiveTurn, marks: RealtimeTurnMarks) async -> Bool {
        let deadline = (marks.lastAudioSentUptime ?? uptime) + RealtimeHeardCheck.transcriptDeadlineAfterReleaseSeconds
        let heard = await marks.waitForHeard(until: deadline)
        turn.line.heardInTime = heard != nil
        // A yes to "want me to go ahead?" resumes with that step approved.
        if liveTurn === turn, walkthrough.awaitingApproval != nil, let answer = GoGuidanceIntent.yesNo(heard) {
            marks.goHandlesTurn = true
            marks.walkthroughReply = ""
            cancelQueuedSpeech(); turn.speechTasks.removeAll(); turn.speechBuffer = GoSpeechBuffer()
            walkthrough.answerApproval(answer)
            if answer { pendingAutopilot = true }
            let text = answer ? phrases.say(.startForMe) : walkthrough.state.message
            marks.walkthroughReply = text
            onGuideText?(text)
            onStateChange?(.idle)
            queueSpeech(text, for: turn)
            return true
        }
        // The yes or no to "delete all your routines?"; anything else keeps them.
        if liveTurn === turn, pendingDeleteAllRoutines {
            pendingDeleteAllRoutines = false
            if let answer = GoGuidanceIntent.yesNo(heard) {
                marks.goHandlesTurn = true
                marks.walkthroughReply = ""
                cancelQueuedSpeech(); turn.speechTasks.removeAll(); turn.speechBuffer = GoSpeechBuffer()
                turn.line.localIntent = "routine.deleteAll." + (answer ? "yes" : "no")
                let deleted = answer && routines.deleteAll()
                if deleted { recentRoutine = nil }
                let text = !answer ? "Okay, I'll keep them." : deleted ? "Done, your routines are deleted." : "I couldn't delete them."
                marks.walkthroughReply = text
                onGuideText?(text)
                onStateChange?(.idle)
                queueSpeech(text, for: turn)
                return true
            }
        }
        // Saved routines: save, run, walk through, list, delete.
        if liveTurn === turn, let heard,
           let intent = GoRoutineIntent.parse(heard, names: routines.routines.map(\.name), recent: recentRoutine),
           let text = await handleRoutine(intent, heard: heard, turn: turn) {
            turn.line.localIntent = "routine." + intent.kind
            marks.goHandlesTurn = true
            marks.walkthroughReply = text
            if walkthrough.state.phase != .waiting { onGuideText?(text) }
            onStateChange?(.idle)
            queueSpeech(text, for: turn)
            return true
        }
        // A question about the step being shown ("where should I type it?"): answered
        // from the step, pointing at it again, so the thread isn't lost.
        if liveTurn === turn, let heard, walkthrough.state.phase == .waiting, walkthrough.state.step != nil,
           GoGuidanceIntent.asksAboutCurrentStep(heard) {
            marks.goHandlesTurn = true
            turn.line.localIntent = "stepQuestion"
            cancelQueuedSpeech(); turn.speechTasks.removeAll(); turn.speechBuffer = GoSpeechBuffer()
            let text = walkthrough.currentStepExplanation()
            marks.walkthroughReply = text
            guide.present(walkthrough.state, spoken: false)
            onGuideText?(text)
            onStateChange?(.idle)
            queueSpeech(text, for: turn)
            return true
        }
        // While Go waits on its own question, the next words are the answer.
        if liveTurn === turn, let heard, GoGuidanceIntent.parse(heard) == nil, walkthrough.state.phase == .needsInput,
           goalStore.activeGoal != nil {
            marks.goHandlesTurn = true
            let saved = goalStore.apply(GoGoalRequest(operation: .update, sourceQuote: heard), heard: heard,
                                        boundRevision: goalStore.state.revision)
            guard saved["ok"] as? Bool == true else { marks.goHandlesTurn = false; return false }
            marks.walkthroughReply = ""
            cancelQueuedSpeech(); turn.speechTasks.removeAll(); turn.speechBuffer = GoSpeechBuffer()
            let cue = phrases.say(.thinking)
            onGuideText?(cue)
            let acknowledgement = acknowledgeIfSlow(turn, saying: cue)
            let resumeForMe = walkthrough.pausedForQuestion
            _ = await walkthrough.proceed(ownerAnswered: true)
            acknowledgement.cancel()
            guard liveTurn === turn else { return true }
            if resumeForMe, walkthrough.state.phase == .waiting { pendingAutopilot = true }
            let state = walkthrough.state
            let text = state.message.isEmpty ? "Okay." : state.message
            if state.phase == .waiting || state.phase == .needsInput { guide.present(state, spoken: false) }
            marks.walkthroughReply = text
            onStateChange?(.idle)
            queueSpeech(text, for: turn)
            return true
        }
        guard liveTurn === turn, let intent = GoGuidanceIntent.parse(heard), let heard else { return false }
        turn.line.localIntent = "guidance"
        marks.goHandlesTurn = true
        marks.walkthroughReply = ""
        cancelQueuedSpeech()
        turn.speechTasks.removeAll()
        turn.speechBuffer = GoSpeechBuffer()
        let cue = phrases.say(.thinking)
        onGuideText?(cue)
        var reply: String?
        var task: String?
        var takesOver = false
        switch intent {
        case .newTask(let words): task = words
        case .doTaskForMe(let words): task = words; takesOver = true
        case .doForMe: takesOver = true
        case .continueGoal: break
        }
        if takesOver {
            var text = phrases.say(.startForMe)
            if let task {
                rememberPreviousRequest()
                let saved = goalStore.apply(GoGuidanceIntent.goalRequest(task: task, heard: heard), heard: heard,
                                            boundRevision: goalStore.state.revision)
                if saved["ok"] as? Bool == true { walkthrough.stop(); pendingAutopilot = true }
                else { text = "I couldn't save that goal. Please try again." }
            } else if goalStore.activeGoal != nil {
                pendingAutopilot = true
            } else {
                text = "What would you like me to do?"
            }
            marks.walkthroughReply = text
            onGuideText?(text)
            onStateChange?(.idle)
            queueSpeech(text, for: turn)
            return true
        }
        if let task {
            rememberPreviousRequest()
            let saved = goalStore.apply(GoGuidanceIntent.goalRequest(task: task, heard: heard), heard: heard,
                                        boundRevision: goalStore.state.revision)
            if saved["ok"] as? Bool != true { reply = "I couldn't save that goal. Please try again." }
        }
        if reply == nil {
            let acknowledgement = acknowledgeIfSlow(turn, saying: cue)
            let result = intent == .continueGoal ? await walkthrough.proceed() : await walkthrough.start()
            acknowledgement.cancel()
            guard liveTurn === turn else { return true }
            let state = walkthrough.state
            if result["ok"] as? Bool == false { reply = result["message"] as? String }
            else if state.phase == .waiting || state.phase == .needsInput || state.phase == .done, !state.message.isEmpty {
                guide.present(state, spoken: false)
                reply = state.message
            }
        }
        guard liveTurn === turn else { return true }
        let text = reply ?? "I couldn't work out the next step here. Try again from the relevant window."
        marks.walkthroughReply = text
        if walkthrough.state.phase != .waiting { onGuideText?(text) }
        onStateChange?(.idle)
        queueSpeech(text, for: turn)
        return true
    }

    private static func milliseconds(from start: TimeInterval?, to end: TimeInterval?) -> Int? {
        guard let start, let end else { return nil }
        return Int(((end - start) * 1000).rounded())
    }

    /// Once per turn. Timings are from key-up.
    private func writeLiveTurnLine(bargedIn: Bool = false, errorKind: String? = nil, emptyReply: String? = nil) {
        guard let liveTurn else { return }
        self.liveTurn = nil
        var line = liveTurn.line
        line.emptyReply = emptyReply
        let released = liveTurn.releasedUptime
        line.holdMs = Self.milliseconds(from: liveTurn.pressedUptime, to: released)
        line.bargedIn = bargedIn
        line.errorKind = errorKind
        line.speechProvider = speechClient.lastFallbackReason.map { "system:" + $0 } ?? "elevenlabs"
        line.ttsRequestMs = Self.milliseconds(from: released, to: liveTurn.speechRequestedUptime)
        line.spokenAudioStartedMs = Self.milliseconds(from: released, to: liveTurn.speechStartedUptime)
        line.notchTransitions = GoNotch.shared.transitions.filter { $0.uptime >= liveTurn.pressedUptime }.map { transition in
            ["state": transition.state, "ms": Self.milliseconds(from: released ?? liveTurn.pressedUptime, to: transition.uptime) ?? 0]
        }
        if let marks = liveTurn.marks {
            let firstDispatch = marks.dispatches.first
            line.firstAudioMs = Self.milliseconds(from: released, to: marks.firstAudioUptime)
            line.toolCalled = !marks.toolCalls.isEmpty
            line.toolName = marks.toolCalls.first?.name
            line.toolCallMs = Self.milliseconds(from: released, to: marks.toolCallUptime)
            line.harnessMs = firstDispatch?.harnessMilliseconds
            line.harnessStatus = firstDispatch?.result["status"] as? String
            line.harnessError = firstDispatch?.result["error"] as? String
            line.freshLook = marks.freshLookOutcome
            line.freshLookMs = marks.freshLookMilliseconds
            line.freshLookArrivedAfterSpeechStartMs = Self.milliseconds(
                from: liveTurn.speechStartedUptime, to: marks.freshLookCompletedUptime)
            line.followUpFirstAudioMs = Self.milliseconds(from: marks.toolResultSentUptime, to: marks.followUpFirstAudioUptime)
            line.releaseToSpokenResultMs = line.spokenAudioStartedMs
            line.turnDoneMs = bargedIn || errorKind != nil ? nil : Self.milliseconds(from: released, to: uptime)
        }
        MeasurementLogFile.appendJSONLine(line.jsonObject, toFileNamed: Self.liveLogFileName)
    }

    private func startMic(targetSampleRate: Int, continuation: AsyncStream<Data>.Continuation) throws {
        let inputNode = micEngine.inputNode
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputNode.outputFormat(forBus: 0),
                             block: Self.makeTapBlock(targetSampleRate: targetSampleRate, continuation: continuation))
        micEngine.prepare()
        try micEngine.start()
    }

    /// Built outside the main actor: the tap runs on the audio thread.
    private nonisolated static func makeTapBlock(
        targetSampleRate: Int, continuation: AsyncStream<Data>.Continuation
    ) -> AVAudioNodeTapBlock {
        let converter = PCM16AudioConverter(targetSampleRate: Double(targetSampleRate))
        return { buffer, _ in
            if let pcmData = converter.convertToPCM16Data(from: buffer) { continuation.yield(pcmData) }
            // One level per buffer for the notch's bars.
            if let channel = buffer.floatChannelData?[0] {
                let rms = GoNotchLevel.rms(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
                Task { @MainActor in GoNotch.shared.setLevel(rms: rms) }
            }
        }
    }

    private func stopMic() {
        micEngine.stop()
        micEngine.inputNode.removeTap(onBus: 0)
    }

    // MARK: Playback

    private func play(_ pcm16Data: Data) {
        let frameCount = pcm16Data.count / 2
        guard frameCount > 0, let buffer = AVAudioPCMBuffer(pcmFormat: playbackFormat, frameCapacity: AVAudioFrameCount(frameCount)) else { return }
        buffer.frameLength = AVAudioFrameCount(frameCount)
        let floatSamples = buffer.floatChannelData![0]
        pcm16Data.withUnsafeBytes { rawBytes in
            for frameIndex in 0..<frameCount {
                let sample = Int16(littleEndian: rawBytes.loadUnaligned(fromByteOffset: frameIndex * 2, as: Int16.self))
                floatSamples[frameIndex] = Float(sample) / 32_768
            }
        }
        if !playbackEngine.isRunning {
            do { try playbackEngine.start() } catch { print("❌ realtime: playback failed to start: \(error)"); return }
        }
        playerNode.scheduleBuffer(buffer)
        if !playerNode.isPlaying {
            playerNode.play()
            onStateChange?(.responding)
        }
    }

    /// Silent when the output device is muted.
    private func playTick(_ tick: GoNotchTick) {
        guard !GoNotchTick.systemOutputIsMuted(), let buffer = tickBuffers[tick] else { return }
        if !playbackEngine.isRunning {
            do { try playbackEngine.start() } catch { print("❌ realtime: playback failed to start: \(error)"); return }
        }
        tickNode.scheduleBuffer(buffer, at: nil, options: .interrupts)
        if !tickNode.isPlaying { tickNode.play() }
    }

    private func stopPlayback() {
        speechClient.stopPlayback()
        errorSpeech.stopSpeaking(at: .immediate)
        playerNode.stop()
    }

    func stop() {
        guide.cancel()
        walkthrough.stop()
        cancelQueuedSpeech()
        turnTask?.cancel()
        audioContinuation?.finish()
        audioContinuation = nil
        writeLiveTurnLine(bargedIn: true)
        stopMic()
        stopPlayback()
        playbackEngine.stop()
        connection?.close()
        connection = nil
    }
}

/// One push-to-talk turn as logged: counts and timings only.
nonisolated struct RealtimeLiveTurnLine {
    let stack: String
    let turnID: String
    let sessionWasWarm: Bool
    var sessionSetupMs: Int?
    var holdMs: Int?
    var firstAudioMs: Int?
    var speechProvider: String?
    var ttsRequestMs: Int?
    var spokenAudioStartedMs: Int?
    var toolCalled = false
    var toolName: String?
    var toolCallMs: Int?
    var harnessMs: Int?
    var harnessStatus: String?
    var harnessError: String?
    var freshLook: String?
    var freshLookMs: Int?
    var freshLookArrivedAfterSpeechStartMs: Int?
    var followUpFirstAudioMs: Int?
    var releaseToSpokenResultMs: Int?
    var turnDoneMs: Int?
    /// Set when the model said nothing and Go answered instead.
    var emptyReply: String?
    var bargedIn = false
    var errorKind: String?
    /// Whether the owner's words arrived in time for Go's own routing.
    var heardInTime: Bool?
    /// Which kind of request Go recognised itself ("routine.run", "guidance"), never the words.
    var localIntent: String?
    /// Each notch state this turn reached, ms from key-up.
    var notchTransitions: [[String: Any]] = []

    init(stack: String, turnID: String, sessionWasWarm: Bool) {
        self.stack = stack
        self.turnID = turnID
        self.sessionWasWarm = sessionWasWarm
    }

    /// Every key is always present, null when unmeasured.
    var jsonObject: [String: Any] {
        func value(_ optional: Any?) -> Any { optional ?? NSNull() }
        return [
            "kind": "turn", "stack": stack, "turnId": turnID,
            "sessionWasWarm": sessionWasWarm, "sessionSetupMs": value(sessionSetupMs),
            "holdMs": value(holdMs), "firstAudioMs": value(firstAudioMs),
            "speechProvider": value(speechProvider), "ttsRequestMs": value(ttsRequestMs),
            "spokenAudioStartedMs": value(spokenAudioStartedMs),
            "toolCalled": toolCalled, "toolName": value(toolName), "toolCallMs": value(toolCallMs),
            "harnessMs": value(harnessMs), "harnessStatus": value(harnessStatus), "harnessError": value(harnessError),
            "freshLook": value(freshLook), "freshLookMs": value(freshLookMs),
            "freshLookArrivedAfterSpeechStartMs": value(freshLookArrivedAfterSpeechStartMs),
            "followUpFirstAudioMs": value(followUpFirstAudioMs), "releaseToSpokenResultMs": value(releaseToSpokenResultMs),
            "turnDoneMs": value(turnDoneMs), "emptyReply": value(emptyReply), "bargedIn": bargedIn, "errorKind": value(errorKind),
            "notchTransitions": notchTransitions,
            "heardInTime": value(heardInTime), "localIntent": value(localIntent)
        ]
    }
}
