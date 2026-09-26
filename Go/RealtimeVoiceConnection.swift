//
//  RealtimeVoiceConnection.swift
//  Go
//
//  One open Gemini Live session with Go's voice tools declared and answered.
//  A turn ends when the model says it is done, no tool call is in flight, and,
//  if a tool ran, the model has spoken since its result was sent.
//

import Foundation

/// Everything one turn did, in uptime seconds.
@MainActor
final class RealtimeTurnMarks {
    var lastAudioSentUptime: TimeInterval?
    var firstAudioUptime: TimeInterval?
    var toolCallUptime: TimeInterval?
    var toolCalls: [RealtimeToolCall] = []
    var dispatches: [RealtimeToolDispatch] = []
    /// One per tool call, in arrival order.
    var decisions: [RealtimeToolDecision] = []
    /// The latest find_menu_items candidates: what a press chooses from.
    var latestMenuOffer: [RealtimeMenuCandidate]?
    var toolResultSentUptime: TimeInterval?
    /// First audio after the latest tool result.
    var followUpFirstAudioUptime: TimeInterval?
    /// The fresh look after a launch: "pending", then "attached" or a refusal code.
    var freshLookOutcome: String?
    var freshLookMilliseconds: Int?
    var freshLookImageBytes: Int?
    var freshLookCompletedUptime: TimeInterval?
    var intentShownUptime: TimeInterval?
    /// Set when the turn finishes; audio after it answers nobody.
    var finishedUptime: TimeInterval?
    var audioChunksAfterFinish = 0
    var transcript = ""
    /// What the user said, from Gemini's separate input transcription. Used by
    /// the heard check; never written to the counts-only logs.
    var heardText = ""
    /// When this turn's transcript was complete (see `heardCompletedUptime(now:)`).
    var heardCompleteUptime: TimeInterval?
    var heardPieceUptimes: [TimeInterval] = []
    /// Transcript pieces arriving before this belong to the previous turn.
    var staleHeardPiecesUntilUptime: TimeInterval?
    /// Calls the heard check refused this turn.
    var heardRefusals = 0
    /// The latest call's work. Calls run in the order the model emitted them.
    var lastCallTask: Task<Void, Never>?
    var outputAudioMime: String?
    var toolsInFlight = 0
    /// Local goal revision for this turn, never supplied by the model.
    var goalRevision: Int?
    var walkthroughReply: String?
    /// Set as soon as the session knows Go answers this turn itself.
    var goHandlesTurn = false
    /// Event names only (never content), with ms after release, so a stalled
    /// turn shows what it last heard.
    var eventTrail: [String] = []
    let finished = GoWaiter<TimeInterval>()

    /// Waits (bounded) for the fresh look before the turn's line is written.
    func waitForFreshLook(timeoutSeconds: Double = 5) async {
        let deadline = ProcessInfo.processInfo.systemUptime + timeoutSeconds
        while freshLookOutcome == "pending", ProcessInfo.processInfo.systemUptime < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    /// Gemini sends no end marker for input transcription, so the transcript is
    /// complete once no new piece has arrived for this long.
    static let geminiHeardQuietSeconds: Double = 0.3

    func heardCompletedUptime(now: TimeInterval) -> TimeInterval? {
        if let heardCompleteUptime { return heardCompleteUptime }
        // Quiet is also counted from the release; 1 µs of slack for float rounding.
        guard let last = heardPieceUptimes.last, let released = lastAudioSentUptime,
              now - max(last, released) >= Self.geminiHeardQuietSeconds - 1e-6 else { return nil }
        return last
    }

    /// The transcript once complete, or nil at the deadline. Tool calls often
    /// arrive before the transcript, so this polls.
    func waitForHeard(until deadlineUptime: TimeInterval) async -> String? {
        while heardCompletedUptime(now: ProcessInfo.processInfo.systemUptime) == nil,
              ProcessInfo.processInfo.systemUptime < deadlineUptime {
            try? await Task.sleep(for: .milliseconds(10))
        }
        guard heardCompletedUptime(now: ProcessInfo.processInfo.systemUptime) != nil else { return nil }
        return heardText
    }

    var freshLookArrivedAfterSpeechStartMs: Int? {
        guard let completed = freshLookCompletedUptime, let spoke = followUpFirstAudioUptime else { return nil }
        return Int(((completed - spoke) * 1000).rounded())
    }
}

@MainActor
final class RealtimeVoiceConnection {
    private let harnessAnswer: @Sendable (String) -> String
    private let goalStore: GoGoalStore?
    private let walkthrough: GoWalkthroughCoordinator?
    private var socket: GoWebSocket?
    private let readyWaiter = GoWaiter<TimeInterval>()
    private(set) var isOpen = false
    private(set) var turn = RealtimeTurnMarks()

    /// False when ElevenLabs plays speech instead of the model's audio.
    var drivesSpeechIndicators = true
    /// PCM16 mono 24 kHz.
    var onAudio: ((Data) -> Void)?
    var onTranscript: ((String, RealtimeTurnMarks) -> Void)?
    var onWalkthroughInstruction: ((String, RealtimeTurnMarks) -> Void)?
    var onTurnFinished: (() -> Void)?
    var onClosed: (() -> Void)?

    /// More tool calls than this in one turn get an error instead of running.
    static let maximumToolCallsPerTurn = 5
    static let supersededError = "superseded"
    /// Gemini Live's voice. Its audio is received, but ElevenLabs does the speaking.
    static let geminiVoice = "Charon"
    /// The provider's name in failure kinds and log lines.
    static let logName = "geminiLive"

    init(harnessAnswer: @escaping @Sendable (String) -> String, goalStore: GoGoalStore? = nil,
         walkthrough: GoWalkthroughCoordinator? = nil) {
        self.harnessAnswer = harnessAnswer
        self.goalStore = goalStore
        self.walkthrough = walkthrough
    }

    private var systemPrompt: String {
        RealtimeOpenAppTool.systemPrompt + (goalStore == nil ? "" : GoGoalTool.instructions) + (walkthrough == nil ? "" : GoWalkthroughTool.instructions)
    }

    private var localDeclarations: [[String: Any]] {
        (goalStore == nil ? [] : [GoGoalTool.declaration]) + (walkthrough == nil ? [] : [GoWalkthroughTool.declaration])
    }

    private var geminiDeclaration: [String: Any] {
        let existing = RealtimeVoiceVerbs.geminiDeclaration["functionDeclarations"] as? [[String: Any]] ?? []
        return ["functionDeclarations": existing + localDeclarations]
    }

    private var uptime: TimeInterval { ProcessInfo.processInfo.systemUptime }

    // MARK: Connect

    /// Token, socket and session setup, until the server acknowledges (about 2 s,
    /// which is why the session pre-warms). The token only needs to be valid at
    /// connect time.
    func connect() async throws {
            let tokenResponse = try await GoVoiceService.fetchWorkerJSON(routePath: "/gemini-live-token", stage: "geminiToken")
            guard let ephemeralToken = tokenResponse["token"] as? String else { throw GoVoiceFailure(kind: "geminiToken:noToken") }
            var components = URLComponents(string: GoVoiceService.geminiLiveConstrainedURL)!
            components.queryItems = [URLQueryItem(name: "access_token", value: ephemeralToken)]
            try await open(URLRequest(url: components.url!))
            try await socket?.sendJSON([
                "setup": [
                    "model": "models/\(GoVoiceService.geminiLiveModel)",
                    "generationConfig": [
                        "responseModalities": ["AUDIO"], "thinkingConfig": ["thinkingLevel": "MINIMAL"],
                        "speechConfig": ["voiceConfig": ["prebuiltVoiceConfig": ["voiceName": Self.geminiVoice]]]
                    ],
                    "systemInstruction": ["parts": [["text": systemPrompt]]],
                    "tools": [geminiDeclaration],
                    "realtimeInputConfig": ["automaticActivityDetection": ["disabled": true]],
                    // What the model said, for the honesty check.
                    "outputAudioTranscription": [String: Any](),
                    // What the user said, for the heard check.
                    "inputAudioTranscription": [String: Any]()
                ]
            ])
        _ = try await readyWaiter.value(timeoutSeconds: 10, timeoutKind: "\(Self.logName):setupTimeout")
        isOpen = true
    }

    private func open(_ request: URLRequest) async throws {
        let socket = GoWebSocket(request: request, session: GoVoiceService.urlSession)
        self.socket = socket
        socket.start(onMessage: { [weak self] message, arrivalUptime in
            self?.handle(message, arrivalUptime: arrivalUptime)
        }, onEnd: { [weak self] error in
            guard let self else { return }
            let failureKind = socket.failureKind(for: error, stage: Self.logName)
            self.isOpen = false
            self.readyWaiter.settle(.failure(GoVoiceFailure(kind: failureKind)))
            self.turn.finished.settle(.failure(GoVoiceFailure(kind: failureKind)))
            self.onClosed?()
        })
    }

    func close() {
        isOpen = false
        socket?.close()
        socket = nil
    }

    // MARK: A turn

    /// Sent before `beginTurn`, and after a verified `open_app` as context.
    func sendScreenshot(_ jpegData: Data) async throws {
        let base64Image = jpegData.base64EncodedString()
        try await socket?.sendJSON(["realtimeInput": ["video": ["mimeType": "image/jpeg", "data": base64Image]]])
    }

    /// Gemini's transcript pieces have no turn id, so pieces arriving in the first
    /// second of a new turn, while the previous transcript is still open, belong
    /// to the previous turn and are dropped.
    static let geminiStaleHeardPieceSeconds: Double = 1.0

    func beginTurn() async throws {
        let previous = turn
        turn = RealtimeTurnMarks()
        turn.goalRevision = goalStore?.state.revision
        if previous.lastAudioSentUptime != nil, previous.heardCompletedUptime(now: uptime) == nil {
            turn.staleHeardPiecesUntilUptime = uptime + Self.geminiStaleHeardPieceSeconds
        }
        try await socket?.sendJSON(["realtimeInput": ["activityStart": [String: Any]()]])
    }

    func appendAudio(_ pcmData: Data) async throws {
        try await socket?.sendJSON(["realtimeInput": ["audio": ["mimeType": "audio/pcm;rate=16000", "data": pcmData.base64EncodedString()]]])
    }

    /// The push-to-talk release.
    func endTurn() async throws {
        turn.lastAudioSentUptime = uptime
        try await socket?.sendJSON(["realtimeInput": ["activityEnd": [String: Any]()]])
    }

    // MARK: Server events

    /// Internal so tests can feed provider events.
    func handle(_ message: [String: Any], arrivalUptime: TimeInterval) {
        recordEvent(message, arrivalUptime: arrivalUptime)
        handleGemini(message, arrivalUptime: arrivalUptime)
    }

    private func handleGemini(_ message: [String: Any], arrivalUptime: TimeInterval) {
        if message["setupComplete"] != nil {
            readyWaiter.settle(.success(arrivalUptime))
        }
        let calls = RealtimeOpenAppTool.parseGemini(message)
        if !calls.isEmpty { receivedToolCalls(calls, arrivalUptime: arrivalUptime) }
        guard let serverContent = message["serverContent"] as? [String: Any] else { return }
        if let spokenPiece = (serverContent["outputTranscription"] as? [String: Any])?["text"] as? String {
            receivedTranscript(spokenPiece)
        }
        if let heardPiece = (serverContent["inputTranscription"] as? [String: Any])?["text"] as? String,
           arrivalUptime >= turn.staleHeardPiecesUntilUptime ?? -.infinity {
            turn.heardText += heardPiece
            turn.heardPieceUptimes.append(arrivalUptime)
        }
        if let parts = (serverContent["modelTurn"] as? [String: Any])?["parts"] as? [[String: Any]] {
            for part in parts {
                guard let inlineData = part["inlineData"] as? [String: Any],
                      let mimeType = inlineData["mimeType"] as? String, mimeType.hasPrefix("audio/"),
                      let audio = Data(base64Encoded: inlineData["data"] as? String ?? "") else { continue }
                if turn.outputAudioMime == nil { turn.outputAudioMime = mimeType }
                receivedAudio(audio, arrivalUptime: arrivalUptime)
            }
        }
        if serverContent["turnComplete"] as? Bool == true {
            receivedTurnDone(arrivalUptime: arrivalUptime)
        }
    }

    private func recordEvent(_ message: [String: Any], arrivalUptime: TimeInterval) {
        guard let released = turn.lastAudioSentUptime, turn.eventTrail.count < 200 else { return }
        var names: [String]
        if let type = message["type"] as? String {
            names = [type]
        } else {
            names = message.keys.sorted()
            if let serverContent = message["serverContent"] as? [String: Any] { names += serverContent.keys.sorted().map { "serverContent." + $0 } }
        }
        // Deltas would drown the trail; their first arrival is already a mark.
        names.removeAll { $0.hasSuffix(".delta") || $0 == "serverContent" || $0 == "serverContent.outputTranscription" }
        guard !names.isEmpty else { return }
        let elapsedMilliseconds = Int(((arrivalUptime - released) * 1000).rounded())
        let entry = names.joined(separator: "+") + "@\(elapsedMilliseconds)"
        if turn.eventTrail.last?.hasPrefix(names.joined(separator: "+") + "@") == true, names == ["serverContent.modelTurn"] { return }
        turn.eventTrail.append(entry)
    }

    private func receivedTranscript(_ text: String) {
        turn.transcript += text
        onTranscript?(text, turn)
    }

    private func receivedAudio(_ audio: Data, arrivalUptime: TimeInterval) {
        if turn.finishedUptime != nil { turn.audioChunksAfterFinish += 1 }
        if turn.firstAudioUptime == nil {
            turn.firstAudioUptime = arrivalUptime
            if drivesSpeechIndicators && turn.toolCalls.isEmpty { GoNotch.shared.handle(.firstAudioWithoutTool) }
        }
        if turn.toolResultSentUptime != nil, turn.followUpFirstAudioUptime == nil { turn.followUpFirstAudioUptime = arrivalUptime }
        onAudio?(audio)
    }

    private func receivedTurnDone(arrivalUptime: TimeInterval) {
        let turn = self.turn
        guard turn.toolsInFlight == 0 else { return }
        if !turn.toolCalls.isEmpty {
            guard let resultSent = turn.toolResultSentUptime, arrivalUptime > resultSent, turn.followUpFirstAudioUptime != nil else { return }
        }
        if turn.finishedUptime == nil { turn.finishedUptime = arrivalUptime }
        turn.finished.settle(.success(arrivalUptime))
        if drivesSpeechIndicators { GoNotch.shared.handle(.turnEnded) }
        onTurnFinished?()
    }

    // MARK: Tool calls

    /// Go is handling this request itself; the model stays quiet.
    static let handledLocally: [String: Any] = ["ok": true, "handledLocally": true,
        "message": "Go is answering this request itself, for this turn only. Do not repeat or add to it. On every later turn, reply aloud as usual."]

    private func receivedToolCalls(_ calls: [RealtimeToolCall], arrivalUptime: TimeInterval) {
        let turn = self.turn
        if turn.toolCallUptime == nil { turn.toolCallUptime = arrivalUptime }
        for call in calls {
            turn.toolCalls.append(call)
            let decisionIndex = turn.decisions.count
            turn.decisions.append(RealtimeToolDecision(call: call, callUptime: arrivalUptime, offeredBeforeCall: turn.latestMenuOffer))
            turn.toolsInFlight += 1
            let overLimit = turn.toolCalls.count > Self.maximumToolCallsPerTurn
            let previousCall = turn.lastCallTask
            turn.lastCallTask = Task { @MainActor [weak self] in
                await previousCall?.value
                var dispatch: RealtimeToolDispatch
                if overLimit {
                    let refusal = RealtimeToolRefusal(error: "tooManyToolCalls", message: "only \(Self.maximumToolCallsPerTurn) tool calls are allowed per turn")
                    dispatch = RealtimeToolDispatch(result: RealtimeOpenAppTool.toolResult(for: refusal), harnessMilliseconds: 0,
                                                    waitedForConfirmation: false, harnessResponse: nil)
                } else if call.name == GoWalkthroughTool.name, let coordinator = self?.walkthrough, let request = call.walkthroughRequest {
                    let heard = request.operation == "status" ? nil : await turn.waitForHeard(
                        until: (turn.lastAudioSentUptime ?? ProcessInfo.processInfo.systemUptime) + RealtimeHeardCheck.transcriptDeadlineAfterReleaseSeconds)
                    guard self?.isOpen == true, self?.turn === turn, turn.finishedUptime == nil else {
                        turn.toolsInFlight -= 1; return
                    }
                    let result: [String: Any]
                    if request.operation == "status" { result = coordinator.status() }
                    else if request.operation == "start", turn.goHandlesTurn || GoGuidanceIntent.parse(heard) != nil
                                || coordinator.state.phase == .needsInput { result = Self.handledLocally }
                    else if let quote = request.sourceQuote, let heard, GoGoalRequest.matchesOwner(quote: quote, heard: heard) {
                        switch request.operation {
                        case "start": result = await coordinator.start()
                        case "stop": coordinator.stop(); result = coordinator.status()
                        default: result = ["ok": false, "error": "invalidWalkthroughOperation"]
                        }
                    } else { result = ["ok": false, "error": "walkthroughNeedsOwnerWords"] }
                    guard self?.turn === turn else { turn.toolsInFlight -= 1; return }
                    if let instruction = result["instruction"] as? String, !instruction.isEmpty {
                        turn.walkthroughReply = instruction
                        self?.onWalkthroughInstruction?(instruction, turn)
                    }
                    dispatch = RealtimeToolDispatch(result: result, harnessMilliseconds: 0, waitedForConfirmation: false, harnessResponse: nil)
                } else if call.name == GoGoalTool.name, let store = self?.goalStore, let request = call.goalRequest {
                    let heard: String?
                    if request.operation == .read {
                        heard = nil
                    } else {
                        heard = await turn.waitForHeard(until: (turn.lastAudioSentUptime ?? ProcessInfo.processInfo.systemUptime)
                                                       + RealtimeHeardCheck.transcriptDeadlineAfterReleaseSeconds)
                    }
                    guard self?.isOpen == true, self?.turn === turn, turn.finishedUptime == nil else {
                        turn.toolsInFlight -= 1
                        return
                    }
                    let guidanceTurn = (request.operation == .set || request.operation == .update)
                        && (turn.goHandlesTurn || GoGuidanceIntent.parse(heard) != nil || self?.walkthrough?.state.phase == .needsInput)
                    let result = guidanceTurn ? Self.handledLocally : store.apply(request, heard: heard, boundRevision: turn.goalRevision)
                    if result["ok"] as? Bool == true { turn.goalRevision = store.state.revision }
                    dispatch = RealtimeToolDispatch(result: result, harnessMilliseconds: 0,
                                                    waitedForConfirmation: false, harnessResponse: nil)
                } else {
                    guard let rawHarnessAnswer = self?.harnessAnswer else { return }
                    let isGoSession = self?.goalStore != nil
                    let ownerWords = isGoSession ? await turn.waitForHeard(
                        until: (turn.lastAudioSentUptime ?? ProcessInfo.processInfo.systemUptime) + RealtimeHeardCheck.transcriptDeadlineAfterReleaseSeconds) : nil
                    // Turns Go handles itself never also act through the model.
                    let allowActions = !isGoSession || (GoVoiceActionPolicy.allowsActions(heard: ownerWords)
                                                        && GoGuidanceIntent.parse(ownerWords) == nil)
                    let harnessAnswer = GoVoiceActionPolicy.guardedAnswer(allowActions: allowActions, answer: rawHarnessAnswer)
                    // Show the intent before the request, from the tool's own argument.
                    let isKnownTool = RealtimeVoiceVerbs.allToolNames.contains(call.name)
                    // Check the user's words against the tool's app before anything runs.
                    let heard = await Self.heardCheck(for: call, in: turn)
                    // The user pressed the key again while this call waited: never run it.
                    @MainActor func recordSuperseded(autoFocus: [String: Any]? = nil) {
                        let refusal = RealtimeToolRefusal(error: Self.supersededError,
                                                          message: "the owner started a new request before this call ran; nothing was done")
                        var superseded = RealtimeToolDispatch(result: RealtimeOpenAppTool.toolResult(for: refusal), harnessMilliseconds: 0,
                                                              waitedForConfirmation: false, harnessResponse: nil)
                        superseded.heardCheck = heard?.trace
                        superseded.autoFocus = autoFocus
                        turn.dispatches.append(superseded)
                        turn.decisions[decisionIndex].dispatch = superseded
                        turn.toolsInFlight -= 1
                    }
                    guard self?.turn === turn else { return recordSuperseded() }
                    if isKnownTool, allowActions || call.name == RealtimeVoiceVerbs.findMenuItemsName {
                        GoNotch.shared.handle(.toolCall(title: RealtimeVoiceVerbs.intentTitle(for: call)))
                        if turn.intentShownUptime == nil { turn.intentShownUptime = self?.uptime }
                    }
                    if !allowActions, call.name != RealtimeVoiceVerbs.findMenuItemsName {
                        dispatch = RealtimeToolDispatch(result: RealtimeOpenAppTool.harnessResponseObject(GoVoiceActionPolicy.refusal),
                                                       harnessMilliseconds: 0, waitedForConfirmation: false, harnessResponse: nil)
                    } else if let refusal = heard?.refusal {
                        dispatch = RealtimeToolDispatch(result: refusal, harnessMilliseconds: 0, waitedForConfirmation: false, harnessResponse: nil)
                        GoNotch.shared.handle(.harnessAnswered(ok: false, subject: RealtimeOpenAppTool.captionName(heard?.heardApp ?? ""),
                                                                   error: refusal["error"] as? String))
                    } else {
                        let onConfirmationRequired: @MainActor () -> Void = {
                            if isKnownTool { GoNotch.shared.handle(.confirmationRequired) }
                        }
                        dispatch = await RealtimeOpenAppTool.dispatch(call, answer: harnessAnswer, onConfirmationRequired: onConfirmationRequired)
                        // Both witnesses name one running app and only the app in front is wrong:
                        // focus it through the harness and run this call once more.
                        let resolvedBundle = dispatch.appCheck?["resolvedBundleId"] as? String
                        let namedAppIsRunning = await Task.detached { resolvedBundle.map { RealtimeVoiceVerbs.isRunning(named: $0) } ?? false }.value
                        if let gate = RealtimeHeardCheck.autoFocusGate(heard: heard?.decision, dispatchError: dispatch.result["error"] as? String,
                                                                       resolvedBundleIdentifier: resolvedBundle, namedAppIsRunning: namedAppIsRunning) {
                            var autoFocus: [String: Any] = ["triggered": gate.triggered, "reason": gate.reason,
                                                            "focusStatus": NSNull(), "focusMs": NSNull(), "retried": false]
                            if allowActions, gate.triggered, let resolvedBundle {
                                let shownName = (dispatch.result["named"] as? String) ?? resolvedBundle
                                GoNotch.shared.handle(.toolCall(title: "Switching to \(RealtimeOpenAppTool.captionName(shownName))\u{2026}"))
                                let focusCall = RealtimeToolCall(callID: call.callID, name: RealtimeVoiceVerbs.focusAppName, appName: resolvedBundle)
                                let focus = await RealtimeOpenAppTool.dispatch(focusCall, answer: harnessAnswer, onConfirmationRequired: onConfirmationRequired)
                                autoFocus["focusStatus"] = focus.harnessConfirmed ? ((focus.result["verification"] as? String) ?? "ok")
                                    : ((focus.result["error"] as? String) ?? "failed")
                                autoFocus["focusMs"] = focus.harnessMilliseconds
                                if !focus.harnessConfirmed {
                                    dispatch.result = focus.result
                                    dispatch.result["message"] = "\(shownName) was not in front, so bringing it forward was tried first, and that "
                                        + "did not work (\((focus.result["message"] as? String) ?? "no reason given")). Nothing was searched or pressed."
                                } else {
                                    guard self?.turn === turn else { return recordSuperseded(autoFocus: autoFocus) }
                                    GoNotch.shared.handle(.toolCall(title: RealtimeVoiceVerbs.intentTitle(for: call)))
                                    dispatch = await RealtimeOpenAppTool.dispatch(call, answer: harnessAnswer, onConfirmationRequired: onConfirmationRequired)
                                    autoFocus["retried"] = true
                                }
                            }
                            dispatch.autoFocus = autoFocus
                        }
                        // Proof only from the harness's own `ok: true`.
                        if isKnownTool, let answered = RealtimeOpenAppTool.notchAnswer(for: call, dispatch: dispatch) {
                            GoNotch.shared.handle(answered)
                        }
                    }
                    dispatch.heardCheck = heard?.trace
                }
                turn.dispatches.append(dispatch)
                turn.decisions[decisionIndex].dispatch = dispatch
                if let offer = dispatch.menuOffer { turn.latestMenuOffer = offer.candidates }
                // Send the verified result now, and add a view of the launched app as
                // context when it arrives.
                if dispatch.harnessConfirmed, call.name == RealtimeOpenAppTool.name, turn.freshLookOutcome == nil,
                   let harnessAnswer = self?.harnessAnswer {
                    turn.freshLookOutcome = "pending"
                    Task { @MainActor [weak self] in await self?.addFreshLook(afterLaunchResponse: dispatch.harnessResponse, answer: harnessAnswer, to: turn) }
                }
                await self?.sendToolResult(dispatch.result, for: call, in: turn)
            }
        }
    }

    /// Waits (bounded) for the transcript, then decides. nil for a call that
    /// names no app.
    private static func heardCheck(for call: RealtimeToolCall, in turn: RealtimeTurnMarks) async
        -> (refusal: [String: Any]?, heardApp: String?, decision: RealtimeHeardCheck.Decision, trace: [String: Any])? {
        guard RealtimeHeardCheck.appliesTo(toolName: call.name), let named = call.appName else { return nil }
        let waitStart = ProcessInfo.processInfo.systemUptime
        let released = turn.lastAudioSentUptime ?? waitStart
        let transcript = await turn.waitForHeard(until: released + RealtimeHeardCheck.transcriptDeadlineAfterReleaseSeconds)
        let waitedMs = Int(((ProcessInfo.processInfo.systemUptime - waitStart) * 1000).rounded())
        // The app list reads the file system, so this runs off main.
        let afterHeardRefusal = turn.heardRefusals > 0
        let menuWords = RealtimeVoiceVerbs.foldedTokens(([call.words ?? ""] + (call.path ?? [])).joined(separator: " "))
        let (decision, namedAppIsRunning) = await Task.detached { () -> (RealtimeHeardCheck.Decision, Bool) in
            let decision = RealtimeHeardCheck.decide(transcript: transcript, named: named, among: RealtimeVoiceVerbs.installedAppNames(),
                                                     afterHeardRefusal: afterHeardRefusal, toolName: call.name, menuWords: menuWords)
            guard decision.outcome == .transcriptMissing, call.name == RealtimeOpenAppTool.name else { return (decision, true) }
            return (decision, RealtimeVoiceVerbs.isRunning(named: named))
        }.value
        let arrivalMs = turn.heardCompletedUptime(now: ProcessInfo.processInfo.systemUptime).map { Int((($0 - released) * 1000).rounded()) }
        let refusal = RealtimeHeardCheck.refusal(for: decision, toolName: call.name, named: named, namedAppIsRunning: namedAppIsRunning)
        if refusal != nil { turn.heardRefusals += 1 }
        return (refusal, decision.heardApps.first, decision,
                RealtimeHeardCheck.traceObject(decision, named: named, transcriptArrivalMs: arrivalMs, waitedMs: waitedMs, refused: refusal != nil))
    }

    /// Adds the fresh look as context, without asking for a reply.
    private func addFreshLook(afterLaunchResponse launchResponse: [String: Any]?,
                              answer: @escaping @Sendable (String) -> String, to turn: RealtimeTurnMarks) async {
        let lookStart = uptime
        var look = await RealtimeOpenAppTool.freshLook(afterLaunchResponse: launchResponse, answer: answer)
        if case .image(let jpeg) = look {
            do { try await sendScreenshot(jpeg) } catch { look = .unavailable(error: "imageSendFailed") }
        }
        turn.freshLookOutcome = look.outcome
        turn.freshLookCompletedUptime = uptime
        turn.freshLookMilliseconds = Int(((uptime - lookStart) * 1000).rounded())
        if case .image(let jpeg) = look { turn.freshLookImageBytes = jpeg.count }
        if case .unavailable(let error) = look { print("🎙️ realtime: no fresh look after open_app: \(error)") }
    }

    private func sendToolResult(_ result: [String: Any], for call: RealtimeToolCall, in turn: RealtimeTurnMarks) async {
        // Decremented before the send, so the follow-up's done event never sees
        // this call as still in flight.
        do {
            turn.toolsInFlight -= 1
            turn.toolResultSentUptime = uptime
            turn.followUpFirstAudioUptime = nil
            try await socket?.sendJSON(["toolResponse": ["functionResponses": [["id": call.callID, "name": call.name, "response": result]]]])
        } catch {
            turn.finished.settle(.failure(GoVoiceFailure(kind: "\(Self.logName):toolResultSendFailed")))
        }
    }
}
