//
//  RealtimeHeardCheckTests.swift
//  GoTests
//
//  The heard check: which apps a transcript names, the decision against the
//  tool's app, the refusal the model is told, and the wait for a late transcript.
//

import Foundation
import Testing
@testable import Go

struct RealtimeHeardCheckTests {

    private func app(_ path: String, _ name: String? = nil, file: Bool = true) -> RealtimeVoiceVerbs.AppName {
        let url = URL(fileURLWithPath: path, isDirectory: true)
        return RealtimeVoiceVerbs.AppName(name: name ?? url.deletingPathExtension().lastPathComponent, url: url, isFileName: file)
    }

    /// A typical set of installed apps, including hard common-word names.
    private var installed: [RealtimeVoiceVerbs.AppName] {
        [app("/Applications/Cursor.app"), app("/Applications/Visual Studio Code.app"), app("/Applications/Google Chrome.app"),
         app("/Applications/Xcode.app"), app("/Users/o/Applications/Claude Code URL Handler.app"), app("/Applications/Claude.app"),
         app("/System/Applications/TextEdit.app"), app("/System/Applications/System Settings.app"),
         app("/System/Applications/Font Book.app"), app("/System/Applications/Time Machine.app"),
         app("/System/Applications/Clock.app"), app("/System/Applications/App Store.app"),
         app("/System/Applications/Preview.app"), app("/System/Applications/Home.app"), app("/System/Applications/Photos.app"),
         app("/System/Applications/Notes.app"),
         app("/Applications/Visual Studio Code.app", "Code", file: false),
         app("/System/Library/CoreServices/Finder.app", "Finder", file: true)]
    }

    private func heard(_ transcript: String) -> [String] {
        RealtimeHeardCheck.appsMentioned(in: transcript, among: installed).apps.map(RealtimeVoiceVerbs.displayName)
    }

    // MARK: Transcript -> apps

    @Test func fullNamesAreHeardWordForWordOrRunTogether() {
        #expect(heard("Open a new window in Cursor.") == ["Cursor"])
        #expect(heard("Open system settings for me.") == ["System Settings"])
        #expect(heard("new text edit document") == ["TextEdit"])
        #expect(heard("Put Finder's toolbar path thing on.") == ["Finder"])
        #expect(heard("open visual studio code") == ["Visual Studio Code"])
        // A word fitting two apps is dropped when an app was named in full: "code" here.
        #expect(heard("Open a new window in the Cursor code editor.") == ["Cursor"])
        #expect(RealtimeHeardCheck.appsMentioned(in: "open cursor", among: installed).tier == .fullName)
        // "claude" is Claude's name and a word of Claude Code URL Handler's: the full name decides.
        #expect(heard("open claude") == ["Claude"])
    }

    @Test func aDistinctiveWordNamesItsAppAndASharedWordIsAmbiguous() {
        #expect(heard("Open a new window in Chrome.") == ["Google Chrome"])
        let code = RealtimeHeardCheck.appsMentioned(in: "Open a new window in code.", among: installed)
        #expect(code.ambiguousWord)
        #expect(code.tier == .word)
        #expect(code.apps.map(RealtimeVoiceVerbs.displayName) == ["Visual Studio Code", "Claude Code URL Handler"])
        // Never by letters: "code" is not Xcode.
        #expect(!code.apps.map(RealtimeVoiceVerbs.displayName).contains("Xcode"))
    }

    @Test func soundAlikesMapOnlyInTheAppSlot() {
        for said in ["open a new window in kasa", "Open a new window in Kaza.", "new window in kassa", "open casa"] {
            let result = RealtimeHeardCheck.appsMentioned(in: said, among: installed)
            #expect(result.apps.map(RealtimeVoiceVerbs.displayName) == ["Cursor"], "\(said)")
            #expect(result.tier == .soundAlike)
        }
        // What transcription actually heard for "cursor".
        for said in ["Open a new window in Cosa.", "Open a new window in Kursor.", "Open a new window in Cursa.", "Open a new window in Kusa."] {
            #expect(heard(said) == ["Cursor"], "\(said)")
        }
        // Beside an ambiguous word the sound-alike is one more candidate: ask, with Cursor offered.
        let editor = RealtimeHeardCheck.appsMentioned(in: "Open a new window in the Kasa code editor.", among: installed)
        #expect(editor.ambiguousWord)
        #expect(editor.apps.map(RealtimeVoiceVerbs.displayName) == ["Cursor", "Visual Studio Code", "Claude Code URL Handler"])
        #expect(RealtimeHeardCheck.soundKey("cursor") == "kasa")
        #expect(RealtimeHeardCheck.soundKey("Kaza") == RealtimeHeardCheck.soundKey("kassa"))
    }

    @Test func conservativeNegativesHearNoApp() {
        #expect(heard("What app am I looking at right now?") == [])
        #expect(heard("Switch to list view.") == [])
        #expect(heard("make the font bigger") == [], "font is Font Book's word and the Format menu's")
        #expect(heard("what time is it") == [])
        #expect(heard("just in case, show the sidebar") == [], "case keys like cursor, and is a stop word")
        #expect(heard("click the export button") == [], "click keys like clock, but is not in the app slot")
        #expect(heard("kasa is not an app here") == [], "a sound-alike outside the app slot")
        #expect(heard("open the app store") == ["App Store"], "a generic word still counts inside a full name")
        #expect(heard("") == [])
    }

    @Test func commonWordNamesCountOnlyWhereOnlyAnAppNameFits() {
        #expect(heard("show the preview pane in finder") == ["Finder"])
        #expect(heard("go home") == [])
        #expect(heard("take notes about the photos") == [])
        #expect(heard("switch to the numbers tab") == [])
        for (said, app) in [("open preview", "Preview"), ("Preview.", "Preview"), ("bring up photos", "Photos"),
                            ("switch to notes", "Notes"), ("go to home", "Home"), ("launch photos please", "Photos"), ("Home, please", "Home")] {
            let result = RealtimeHeardCheck.appsMentioned(in: said, among: installed)
            #expect(result.apps.map(RealtimeVoiceVerbs.displayName) == [app], "\(said)")
            #expect(result.tier == .slot, "\(said)")
        }
        // Never as a sound-alike or a word: "note" in the slot is not Notes.
        #expect(heard("open the note") == [])
    }

    // MARK: Decision

    @Test func theDecisionTable() {
        func outcome(_ transcript: String?, named: String) -> RealtimeHeardCheck.Outcome {
            RealtimeHeardCheck.decide(transcript: transcript, named: named, among: installed).outcome
        }
        #expect(outcome("open a new window in cursor", named: "Cursor") == .match)
        // The user said Cursor; the model named VS Code.
        #expect(outcome("open a new window in cursor", named: "Visual Studio Code") == .heardNamedMismatch)
        #expect(outcome("switch finder to list view", named: "Finder") == .match)
        #expect(outcome("switch to list view", named: "Finder") == .noAppHeard)
        #expect(outcome("open a new window in code", named: "Visual Studio Code") == .ambiguousApp)
        #expect(outcome("open cursor and chrome", named: "Cursor") == .ambiguousApp)
        // Gemini's "Kasa": the tool names an app that is not installed; the words sound like Cursor.
        #expect(outcome("open a new window in kasa", named: "Kasa") == .heardNamedMismatch)
        // A name the identity check will ask about downstream is not contradicted here.
        #expect(outcome("open visual studio code", named: "code") == .match)
        #expect(outcome(nil, named: "Cursor") == .transcriptMissing)
        #expect(outcome("  ", named: "Cursor") == .transcriptMissing)
        let mismatch = RealtimeHeardCheck.decide(transcript: "new window in cursor", named: "Visual Studio Code", among: installed)
        #expect(mismatch.heardApps == ["Cursor"])
        // After a refusal this turn, re-calling with an app the words only GUESSED is not the owner's answer.
        func retry(_ transcript: String, named: String) -> RealtimeHeardCheck.Outcome {
            RealtimeHeardCheck.decide(transcript: transcript, named: named, among: installed, afterHeardRefusal: true).outcome
        }
        #expect(retry("open a new window in kasa", named: "Cursor") == .unconfirmedRetry)
        #expect(outcome("open a new window in kasa", named: "Cursor") == .match)
        #expect(retry("open a new window in chrome", named: "Google Chrome") == .unconfirmedRetry)
        #expect(retry("open a new window in cursor", named: "Cursor") == .match)
        #expect(retry("open preview", named: "Preview") == .match)
        #expect(mismatch.refusalError == "heardNamedMismatch")
    }

    @Test func anUncaughtNameInTheAppSlotAsksBeforeAMenuToolAndIsLogged() {
        func decide(_ transcript: String, tool: String, menuWords: [String] = []) -> RealtimeHeardCheck.Decision {
            RealtimeHeardCheck.decide(transcript: transcript, named: "Cursor", among: installed, toolName: tool, menuWords: menuWords)
        }
        let unclear = decide("Open a new window in Zorbit.", tool: "press_menu")
        #expect(unclear.outcome == .appNameUnclear)
        #expect(unclear.heardSlot == ["zorbit"])
        #expect(RealtimeHeardCheck.refusal(for: unclear, toolName: "press_menu", named: "Cursor")?["error"] as? String == "heardUnavailable")
        #expect(decide("Open a new window in Zorbit.", tool: "find_menu_items").outcome == .appNameUnclear)
        // Only the menu tools: open and focus keep their own guards.
        #expect(decide("Open a new window in Zorbit.", tool: "focus_app").outcome == .noAppHeard)
        // English, a modern word, a menu word of the call itself, or a sound-alike: not a missed name.
        #expect(decide("switch to list view", tool: "press_menu") == RealtimeHeardCheck.Decision(outcome: .noAppHeard, heardApps: [], tier: nil))
        #expect(decide("show the sidebar", tool: "press_menu").outcome == .noAppHeard)
        #expect(decide("show all the windows", tool: "press_menu").outcome == .noAppHeard, "Webster's lists window, not windows")
        #expect(decide("hide the minimap", tool: "press_menu", menuWords: ["view", "hide", "minimap"]).outcome == .noAppHeard)
        let kasa = decide("open a new window in kasa", tool: "press_menu")
        #expect(kasa.outcome == .match)
        #expect(kasa.heardSlot == ["kasa"])
        #expect(RealtimeHeardCheck.isEnglishWord("window") && !RealtimeHeardCheck.isEnglishWord("zorbit"))
        #expect(RealtimeHeardCheck.englishWords.count > 200_000, "the system word list was read")
    }

    @Test func refusalsNameTheAppsAndOnlyAPressFailsClosedWithoutATranscript() {
        let mismatch = RealtimeHeardCheck.decide(transcript: "new window in cursor", named: "Visual Studio Code", among: installed)
        let told = RealtimeHeardCheck.refusal(for: mismatch, toolName: "press_menu", named: "Visual Studio Code") ?? [:]
        #expect(told["ok"] as? Bool == false)
        #expect(told["error"] as? String == "heardNamedMismatch")
        #expect(told["heard"] as? String == "Cursor")
        #expect(told["named"] as? String == "Visual Studio Code")
        #expect((told["message"] as? String)?.hasSuffix("whether they meant Cursor.") == true)

        // A guess is worded as one.
        let guessed = RealtimeHeardCheck.decide(transcript: "new window in kasa", named: "Visual Studio Code", among: installed)
        let guessedMessage = RealtimeHeardCheck.refusal(for: guessed, toolName: "press_menu", named: "Visual Studio Code")?["message"] as? String
        #expect(guessedMessage?.hasPrefix("the owner may have said Cursor, but") == true)
        #expect((told["message"] as? String)?.hasPrefix("the owner said Cursor, but") == true)
        let retried = RealtimeHeardCheck.decide(transcript: "new window in kasa", named: "Cursor", among: installed, afterHeardRefusal: true)
        let retriedTold = RealtimeHeardCheck.refusal(for: retried, toolName: "focus_app", named: "Cursor") ?? [:]
        #expect(retriedTold["error"] as? String == "heardUnconfirmed")
        #expect((retriedTold["message"] as? String)?.contains("may have said Cursor") == true)

        let ambiguous = RealtimeHeardCheck.decide(transcript: "open a new window in code", named: "Code", among: installed)
        let asked = RealtimeHeardCheck.refusal(for: ambiguous, toolName: "focus_app", named: "Code") ?? [:]
        #expect(asked["error"] as? String == "ambiguousApp")
        #expect(asked["candidates"] as? [String] == ["Visual Studio Code", "Claude Code URL Handler"])

        let missing = RealtimeHeardCheck.decide(transcript: nil, named: "Cursor", among: installed)
        #expect(RealtimeHeardCheck.refusal(for: missing, toolName: "press_menu", named: "Cursor")?["error"] as? String == "heardUnavailable")
        for tool in ["open_app", "focus_app", "find_menu_items"] {
            #expect(RealtimeHeardCheck.refusal(for: missing, toolName: tool, named: "Cursor", namedAppIsRunning: true) == nil, "\(tool)")
        }
        // A launch is not undone by one more request: with no transcript it asks.
        let launch = RealtimeHeardCheck.refusal(for: missing, toolName: "open_app", named: "Cursor", namedAppIsRunning: false) ?? [:]
        #expect(launch["error"] as? String == "heardUnavailable")
        #expect((launch["message"] as? String)?.contains("Nothing was opened") == true)
        #expect(RealtimeHeardCheck.refusal(for: missing, toolName: "focus_app", named: "Cursor", namedAppIsRunning: false) == nil)
        let match = RealtimeHeardCheck.decide(transcript: "open cursor", named: "Cursor", among: installed)
        #expect(RealtimeHeardCheck.refusal(for: match, toolName: "press_menu", named: "Cursor") == nil)

        let trace = RealtimeHeardCheck.traceObject(mismatch, named: "Visual Studio Code", transcriptArrivalMs: 812, waitedMs: 40, refused: true)
        #expect(Set(trace.keys) == ["outcome", "heardApps", "tier", "named", "transcriptArrivalMs", "waitedMs", "heardSlot", "refused"])
        #expect(trace["refused"] as? Bool == true)
        #expect(trace["outcome"] as? String == "heardNamedMismatch")
    }

    @Test func thePromptTellsTheModelToAskNotCheck() {
        #expect(RealtimeOpenAppTool.systemPrompt.contains("if a tool returns heardNamedMismatch or ambiguousApp, ask the owner which app they meant, briefly; never focus or open an app to check first."))
    }

    // MARK: The bounded wait

    @MainActor @Test func aLateTranscriptIsWaitedForAndAMissingOneIsNot() async {
        let turn = RealtimeTurnMarks()
        let now = ProcessInfo.processInfo.systemUptime
        turn.lastAudioSentUptime = now
        // Never arrives: nil at the deadline, not before.
        let missing = await turn.waitForHeard(until: now + 0.15)
        #expect(missing == nil)
        #expect(ProcessInfo.processInfo.systemUptime >= now + 0.15)

        // An explicit completion that lands after the call began waiting.
        let late = RealtimeTurnMarks()
        late.lastAudioSentUptime = ProcessInfo.processInfo.systemUptime
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(60))
            late.heardText = "open a new window in cursor"
            late.heardCompleteUptime = ProcessInfo.processInfo.systemUptime
        }
        let arrived = await late.waitForHeard(until: ProcessInfo.processInfo.systemUptime + 2)
        #expect(arrived == "open a new window in cursor")

        // Gemini: pieces with no end marker count once quiet for geminiHeardQuietSeconds after the release.
        let gemini = RealtimeTurnMarks()
        let released = ProcessInfo.processInfo.systemUptime
        gemini.lastAudioSentUptime = released
        gemini.heardText = "open a new window"
        gemini.heardPieceUptimes = [released]
        #expect(gemini.heardCompletedUptime(now: released + 0.1) == nil)
        #expect(gemini.heardCompletedUptime(now: released + RealtimeTurnMarks.geminiHeardQuietSeconds) == released)
        // Exactly at the boundary at every uptime, not just where 0.3 rounds up (IEEE).
        for base in [1.1, 12_345.678, 98_765.4321, 1_000_000.7] {
            let marks = RealtimeTurnMarks()
            marks.lastAudioSentUptime = base
            marks.heardPieceUptimes = [base]
            #expect(marks.heardCompletedUptime(now: base + RealtimeTurnMarks.geminiHeardQuietSeconds) == base, "\(base)")
        }
    }

    // MARK: Turns that overlap

    @MainActor @Test func geminiPiecesOfThePreviousTurnAreDroppedNotAppended() async throws {
        let connection = RealtimeVoiceConnection(harnessAnswer: { _ in "{}" })
        func piece(_ text: String, at uptime: TimeInterval) {
            connection.handle(["serverContent": ["inputTranscription": ["text": text]]], arrivalUptime: uptime)
        }
        try await connection.beginTurn()
        try await connection.endTurn()
        piece("open a new window in", at: ProcessInfo.processInfo.systemUptime)
        // The next turn begins while that transcript is still open (not yet quiet).
        try await connection.beginTurn()
        let began = ProcessInfo.processInfo.systemUptime
        piece(" cursor", at: began + 0.2)
        #expect(connection.turn.heardText.isEmpty)
        piece("switch to list view", at: began + RealtimeVoiceConnection.geminiStaleHeardPieceSeconds + 0.5)
        #expect(connection.turn.heardText == "switch to list view")
        // A turn begun after the last one's transcript was complete drops nothing.
        try await connection.endTurn()
        connection.turn.heardCompleteUptime = ProcessInfo.processInfo.systemUptime
        try await connection.beginTurn()
        piece("open finder", at: ProcessInfo.processInfo.systemUptime)
        #expect(connection.turn.heardText == "open finder")
    }

    @MainActor @Test func aCallWhoseTurnWasSupersededWhileItWaitedNeverReachesTheHarness() async throws {
        final class Requests: @unchecked Sendable {
            private let lock = NSLock()
            private var lines: [String] = []
            func add(_ line: String) { lock.lock(); lines.append(line); lock.unlock() }
            var count: Int { lock.lock(); defer { lock.unlock() }; return lines.count }
        }
        let requests = Requests()
        let connection = RealtimeVoiceConnection(harnessAnswer: { line in requests.add(line); return "{}" })
        try await connection.beginTurn()
        try await connection.endTurn()
        connection.handle(["serverContent": ["inputTranscription": ["text": "open a new window in finder"]]],
                          arrivalUptime: ProcessInfo.processInfo.systemUptime)
        connection.handle(["toolCall": ["functionCalls": [["id": "c1", "name": "press_menu",
                                                           "args": ["app": "Finder", "path": ["File", "New Finder Window"]]]]]],
                          arrivalUptime: ProcessInfo.processInfo.systemUptime)
        let first = connection.turn
        // The owner presses the key again while the call waits for the transcript to go quiet.
        try await connection.beginTurn()
        let deadline = ProcessInfo.processInfo.systemUptime + 4
        while first.decisions.first?.dispatch == nil, ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(first.decisions.first?.dispatch?.result["error"] as? String == "superseded")
        #expect(requests.count == 0)
    }

    @MainActor @Test func callsReachTheHarnessInTheOrderTheModelEmittedThem() async throws {
        // The focus waits for the transcript and answers slowly; the unknown tool
        // would finish at once. Emitted focus-then-bogus, they must finish so.
        let connection = RealtimeVoiceConnection(harnessAnswer: { _ in Thread.sleep(forTimeInterval: 0.2); return "{}" })
        try await connection.beginTurn()
        try await connection.endTurn()
        connection.handle(["serverContent": ["inputTranscription": ["text": "switch to finder"]]], arrivalUptime: ProcessInfo.processInfo.systemUptime)
        connection.handle(["toolCall": ["functionCalls": [["id": "c1", "name": "focus_app", "args": ["name": "Finder"]],
                                                          ["id": "c2", "name": "bogus_tool", "args": [String: Any]()]]]],
                          arrivalUptime: ProcessInfo.processInfo.systemUptime)
        let turn = connection.turn
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while turn.dispatches.count < 2, ProcessInfo.processInfo.systemUptime < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(turn.dispatches.count == 2)
        #expect(turn.dispatches.first?.result["error"] as? String != "unknownTool")
        #expect(turn.dispatches.last?.result["error"] as? String == "unknownTool")
    }

    // MARK: Auto-focus

    @Test func autoFocusOnlyWhenStrongWordsAndToolAgreeOnARunningApp() {
        func gate(_ transcript: String?, named: String, afterRefusal: Bool = false, error: String? = "appMismatch",
                  bundle: String? = "com.example.app", running: Bool = true) -> RealtimeHeardCheck.AutoFocusGate? {
            let decision = RealtimeHeardCheck.decide(transcript: transcript, named: named, among: installed, afterHeardRefusal: afterRefusal)
            return RealtimeHeardCheck.autoFocusGate(heard: decision, dispatchError: error, resolvedBundleIdentifier: bundle, namedAppIsRunning: running)
        }
        let agree = RealtimeHeardCheck.AutoFocusGate(triggered: true, reason: "witnessesAgree")
        // Full name and common-word slot: both witnesses, strong evidence.
        #expect(gate("switch finder to list view", named: "Finder") == agree)
        #expect(gate("open preview", named: "Preview") == agree)
        // Only appMismatch raises the question at all.
        #expect(gate("switch finder to list view", named: "Finder", error: nil) == nil)
        #expect(gate("switch finder to list view", named: "Finder", error: "notVerified") == nil)
        #expect(gate("switch finder to list view", named: "Finder", error: "frontmostChanged") == nil)
        // Not running: open_app's job (its own heard check), never a launch from here.
        #expect(gate("switch finder to list view", named: "Finder", running: false) == .init(triggered: false, reason: "notRunning"))
        #expect(gate("switch finder to list view", named: "Finder", bundle: nil) == .init(triggered: false, reason: "unresolved"))
        // A guess is not the user's word: a sound-alike, or a distinctive word ("chrome").
        #expect(gate("open a new window in kasa", named: "Cursor") == .init(triggered: false, reason: "tier:soundAlike"))
        #expect(gate("open a new window in chrome", named: "Google Chrome") == .init(triggered: false, reason: "tier:word"))
        // Anything but a match.
        #expect(gate("open a new window in code", named: "Visual Studio Code") == .init(triggered: false, reason: "heard:ambiguousApp"))
        #expect(gate("open a new window in chrome", named: "Google Chrome", afterRefusal: true)
                == .init(triggered: false, reason: "heard:unconfirmedRetry"))
        #expect(gate("open a new window in cursor", named: "Visual Studio Code") == .init(triggered: false, reason: "heard:heardNamedMismatch"))
        #expect(gate("switch to list view", named: "Finder") == .init(triggered: false, reason: "heard:noAppHeard"))
        #expect(gate(nil, named: "Finder") == .init(triggered: false, reason: "heard:transcriptMissing"))
        #expect(RealtimeHeardCheck.autoFocusGate(heard: nil, dispatchError: "appMismatch", resolvedBundleIdentifier: "x", namedAppIsRunning: true)
                == .init(triggered: false, reason: "heard:notChecked"))
    }

    @MainActor @Test func anAutoFocusFocusesOnceThenRerunsOnceAndNeverLoops() async throws {
        final class Requests: @unchecked Sendable {
            private let lock = NSLock()
            private var verbs: [String] = []
            func add(_ verb: String) { lock.lock(); verbs.append(verb); lock.unlock() }
            var all: [String] { lock.lock(); defer { lock.unlock() }; return verbs }
        }
        let requests = Requests()
        // Something else stays in front whatever is focused: the re-run mismatches again, and must stop there.
        let connection = RealtimeVoiceConnection(harnessAnswer: { line in
            let verb = (RealtimeOpenAppTool.harnessResponseObject(line)["verb"] as? String) ?? "?"
            requests.add(verb)
            return verb == "focus" ? #"{"ok":true,"verification":{"status":"confirmed"}}"#
                : #"{"ok":false,"error":"frontmostChanged","actualApp":{"name":"Cursor","bundleIdentifier":"com.todesktop.230313mzl4w4u92"}}"#
        })
        try await connection.beginTurn()
        try await connection.endTurn()
        connection.handle(["serverContent": ["inputTranscription": ["text": "switch finder to list view"]]],
                          arrivalUptime: ProcessInfo.processInfo.systemUptime)
        connection.handle(["toolCall": ["functionCalls": [["id": "c1", "name": "find_menu_items", "args": ["app": "Finder", "words": "list view"]]]]],
                          arrivalUptime: ProcessInfo.processInfo.systemUptime)
        let turn = connection.turn
        let deadline = ProcessInfo.processInfo.systemUptime + 6
        while turn.decisions.first?.dispatch == nil, ProcessInfo.processInfo.systemUptime < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(requests.all == ["menus", "focus", "menus"])
        let autoFocus = turn.decisions.first?.dispatch?.autoFocus
        #expect(autoFocus?["triggered"] as? Bool == true)
        #expect(autoFocus?["focusStatus"] as? String == "confirmed")
        #expect(autoFocus?["retried"] as? Bool == true)
        #expect(turn.decisions.first?.dispatch?.result["error"] as? String == "appMismatch")
    }

    // MARK: Notch

    @Test func theNotchSaysWhichAppItHeard() {
        #expect(GoNotchReason.plain(forErrorCode: "heardNamedMismatch", subject: "Cursor") == "heard Cursor, asking first")
        let long = GoNotchReason.plain(forErrorCode: "heardNamedMismatch", subject: "Claude Code URL Handler")
        #expect(long == "heard another app, asking first")
        #expect(long.count <= GoNotchReason.maximumLength)
        #expect(GoNotchReason.plain(forErrorCode: "heardUnavailable").count <= GoNotchReason.maximumLength)
        #expect(GoNotchReason.plain(forErrorCode: "heardUnconfirmed").count <= GoNotchReason.maximumLength)
        #expect(GoNotchReason.plain(forErrorCode: "appMismatch", subject: "Cursor") == "a different app is in front")
        #expect(GoNotchState.thinking.next(on: .toolCall(title: "x"))?.next(on: .harnessAnswered(ok: false, subject: "Cursor", error: "heardNamedMismatch"))
                == .didntTake(reason: "heard Cursor, asking first"))
    }
}
