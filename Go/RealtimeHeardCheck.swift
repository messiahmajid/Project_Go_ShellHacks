//
//  RealtimeHeardCheck.swift
//  Go
//
//  Before an app-targeted voice tool runs, the app the tool names is compared
//  with the app(s) the user's own words name, from Gemini Live's separate
//  input transcription. If the model misheard, Go asks instead of acting in
//  the wrong app. The transcript is compared locally and never logged.
//

import Foundation

nonisolated enum RealtimeHeardCheck {
    static let mismatchError = "heardNamedMismatch"
    static let unavailableError = "heardUnavailable"
    static let unconfirmedError = "heardUnconfirmed"

    /// How long after push-to-talk release a tool call may wait for the transcript.
    static let transcriptDeadlineAfterReleaseSeconds: Double = 2.5

    // MARK: Which apps the words name

    /// Evidence tiers, strongest first. A word that fits two apps counts only when
    /// no app was named in full; sound-alikes only when nothing else was heard.
    enum Tier: String {
        /// An app's file name, word for word or run together ("text edit").
        case fullName
        /// A common-word app name ("Preview") heard where only an app name fits.
        case slot
        /// A running app's menu-bar name ("Code"), or a distinctive word ("chrome").
        case word
        /// Sounds like a one-word app name ("kasa" for Cursor).
        case soundAlike

        /// Evidence strong enough for the model to retry with the heard app after
        /// a refusal this turn.
        var confirmsARetry: Bool { self == .fullName || self == .slot }
        /// The refusal says "may have said", not "said".
        var isTentative: Bool { self == .soundAlike || self == .slot }
    }

    struct HeardApps: Equatable {
        /// Distinct apps, in order of first mention.
        let apps: [URL]
        /// A single word fits two or more apps ("code").
        let ambiguousWord: Bool
        let tier: Tier?

        static let none = HeardApps(apps: [], ambiguousWord: false, tier: nil)
    }

    /// Words of multi-word app names that are ordinary words, so they never name
    /// an app alone ("font", "time").
    static let genericNameWords: Set<String> = [
        "app", "apps", "google", "microsoft", "system", "utility", "assistant", "player", "center", "centre",
        "editor", "script", "classic", "handler", "image", "photo", "screen", "sharing", "information",
        "capture", "font", "book", "time", "machine", "control", "file", "exchange", "audio", "setup", "print",
        "color", "digital", "meter", "word", "flow", "toolbox", "zoom", "window", "store", "memos", "mirroring"
    ]

    /// One-word app names that are everyday words ("Preview", "Home"). They name
    /// an app only in the app slot or as the whole utterance.
    static let commonWordAppNames: Set<String> = [
        "preview", "home", "photos", "music", "notes", "maps", "news", "pages", "numbers", "clock", "contacts",
        "stocks", "mail", "books", "reminders", "calendar", "messages", "weather", "shortcuts", "podcasts", "tv",
        "tips", "passwords", "journal", "games", "phone", "chess", "stickies", "freeform"
    ]
    static let commonNameSlotLeadWords: Set<String> = ["open", "in", "to", "launch"]
    /// Dropped before asking whether the utterance is just the name.
    static let fillerWords: Set<String> = ["the", "app", "please", "now", "hey", "ok", "okay"]

    static func isInCommonNameSlot(_ spoken: [String], at index: Int) -> Bool {
        guard index > 0 else { return false }
        if commonNameSlotLeadWords.contains(spoken[index - 1]) { return true }
        return index > 1 && spoken[index - 2] == "bring" && spoken[index - 1] == "up"
    }

    /// Sound-alikes are only matched in the app slot (after one of these, or the
    /// last word), so "click" is never heard as Clock.
    static let appSlotLeadWords: Set<String> = ["in", "into", "to", "on", "from", "open", "launch", "focus", "switch", "use", "the"]
    /// Everyday words that share a sound key with an installed app. A wrong hit
    /// only makes the check ask, never act.
    static let soundAlikeStopWords: Set<String> = ["case", "cause", "course", "coarse", "curse", "click", "clerk", "commit", "decay", "nation", "sticks", "worthy"]

    /// A rough English sound key: "cursor", "kasa" and "kassa" all key to "kasa".
    /// The tiers and the app slot keep it conservative.
    static func soundKey(_ word: String) -> String {
        let vowels: Set<Character> = ["a", "e", "i", "o", "u", "y"]
        var letters = word.lowercased().filter { $0.isASCII && $0.isLetter }
        for (from, to) in [("ph", "f"), ("ck", "k"), ("qu", "kw"), ("x", "ks")] {
            letters = letters.replacingOccurrences(of: from, with: to)
        }
        let characters = Array(letters)
        var keyed: [Character] = []
        for (index, character) in characters.enumerated() {
            let next: Character? = index + 1 < characters.count ? characters[index + 1] : nil
            var mapped = character
            switch character {
            case "c": mapped = next.map { "eiy".contains($0) } == true ? "s" : "k"
            case "q": mapped = "k"
            case "z": mapped = "s"
            case "r" where next.map { !vowels.contains($0) } ?? true: continue
            default: break
            }
            if vowels.contains(mapped) { mapped = "a" }
            if keyed.last != mapped { keyed.append(mapped) }
        }
        return String(keyed)
    }

    static func appsMentioned(in transcript: String, among names: [RealtimeVoiceVerbs.AppName]) -> HeardApps {
        let spoken = RealtimeVoiceVerbs.foldedTokens(transcript)
        guard !spoken.isEmpty else { return .none }
        func path(_ url: URL) -> String { url.standardizedFileURL.path }
        func distinct(_ urls: [URL]) -> [URL] {
            var seen = Set<String>()
            return urls.filter { seen.insert(path($0)).inserted }
        }
        func starts(_ name: String) -> [Int] {
            let wanted = RealtimeVoiceVerbs.foldedTokens(name).joined()
            guard !wanted.isEmpty else { return [] }
            return spoken.indices.filter { start in
                var joined = ""
                for word in spoken[start...] {
                    joined += word
                    if joined == wanted { return true }
                    if joined.count >= wanted.count || !wanted.hasPrefix(joined) { return false }
                }
                return false
            }
        }
        func said(_ name: String) -> Bool { !starts(name).isEmpty }
        func isCommonWord(_ name: RealtimeVoiceVerbs.AppName) -> Bool {
            let tokens = RealtimeVoiceVerbs.foldedTokens(name.name)
            return tokens.count == 1 && commonWordAppNames.contains(tokens[0])
        }
        let unpadded = spoken.filter { !fillerWords.contains($0) }.joined()

        let fullNames = distinct(names.filter { $0.isFileName && !isCommonWord($0) && said($0.name) }.map(\.url))
        let slotNames = distinct(names.filter { name in
            isCommonWord(name) && (starts(name.name).contains { isInCommonNameSlot(spoken, at: $0) }
                                   || unpadded == RealtimeVoiceVerbs.foldedTokens(name.name).joined())
        }.map(\.url))

        var appsByWord: [String: [URL]] = [:]
        for name in names where !isCommonWord(name) {
            let tokens = RealtimeVoiceVerbs.foldedTokens(name.name)
            if !name.isFileName || tokens.count == 1 { appsByWord[tokens.joined(), default: []].append(name.url) }
            guard tokens.count > 1 else { continue }
            for token in Set(tokens) where token.count >= 4 && !genericNameWords.contains(token) {
                appsByWord[token, default: []].append(name.url)
            }
        }
        var wordApps = names.filter { !$0.isFileName && RealtimeVoiceVerbs.foldedTokens($0.name).count > 1 && said($0.name) }.map(\.url)
        var ambiguousWordApps: [URL] = []
        for word in spoken {
            guard let apps = appsByWord[word].map(distinct) else { continue }
            if apps.count > 1 { ambiguousWordApps += apps } else { wordApps += apps }
        }
        if !fullNames.isEmpty || !slotNames.isEmpty {
            return HeardApps(apps: distinct(fullNames + slotNames + wordApps), ambiguousWord: false, tier: fullNames.isEmpty ? .slot : .fullName)
        }
        if !wordApps.isEmpty {
            return HeardApps(apps: distinct(wordApps + ambiguousWordApps), ambiguousWord: !ambiguousWordApps.isEmpty, tier: .word)
        }
        var ambiguousWord = !ambiguousWordApps.isEmpty

        // Sound-alikes: one-word names of five+ letters, words of four+ in the app slot.
        var appsByKey: [String: [URL]] = [:]
        for name in names where !isCommonWord(name) {
            let tokens = RealtimeVoiceVerbs.foldedTokens(name.name)
            guard tokens.count == 1, tokens[0].count >= 5 else { continue }
            appsByKey[soundKey(tokens[0]), default: []].append(name.url)
        }
        var soundApps: [URL] = []
        for (index, word) in spoken.enumerated() {
            let inSlot = index == spoken.count - 1 || (index > 0 && appSlotLeadWords.contains(spoken[index - 1]))
            guard inSlot, word.count >= 4, !soundAlikeStopWords.contains(word),
                  let apps = appsByKey[soundKey(word)].map(distinct) else { continue }
            if apps.count > 1 { ambiguousWord = true }
            soundApps += apps
        }
        // A sound-alike beside an ambiguous word is one more candidate, not the answer.
        if !ambiguousWordApps.isEmpty { return HeardApps(apps: distinct(soundApps + ambiguousWordApps), ambiguousWord: true, tier: .word) }
        if !soundApps.isEmpty { return HeardApps(apps: distinct(soundApps), ambiguousWord: ambiguousWord, tier: .soundAlike) }
        return .none
    }

    // MARK: The app slot

    /// Where the app name goes: the word after one of these, or the last word.
    /// Wider than the matching slots, since this only logs or asks.
    static let heardSlotLeadWords: Set<String> = ["in", "to", "the", "open", "for"]

    /// macOS's word list (`/usr/share/dict/words`), lowercased. Empty if
    /// unreadable, which makes every unknown slot word ask.
    static let englishWords: Set<String> = {
        guard let text = try? String(contentsOfFile: "/usr/share/dict/words", encoding: .utf8) else { return [] }
        return Set(text.split(separator: "\n").map { $0.lowercased() })
    }()
    /// Everyday computing words the old dictionary lacks.
    static let modernWords: Set<String> = [
        "email", "desktop", "download", "online", "inbox", "screenshot", "popup", "dropdown", "toolbar", "sidebar",
        "fullscreen", "emoji", "website", "homepage", "wifi", "bluetooth", "login", "logout", "username", "app", "apps",
        "tab", "tabs", "url", "browser", "devtools", "incognito", "workspace", "terminal", "settings", "okay"
    ]

    /// Plural and verb endings stripped once.
    static func isEnglishWord(_ word: String) -> Bool {
        if englishWords.contains(word) || modernWords.contains(word) { return true }
        return ["s", "es", "ed", "ing"].contains { suffix in
            word.count > suffix.count + 2 && word.hasSuffix(suffix) && englishWords.contains(String(word.dropLast(suffix.count)))
        }
    }

    struct SlotReading: Equatable {
        /// Slot words that are not ordinary English, or that name or sound like an app.
        let logged: [String]
        /// Slot words that are no app, sound-alike, English word or menu word.
        let unrecognised: [String]
    }

    static func readSlot(_ spoken: [String], among names: [RealtimeVoiceVerbs.AppName], menuWords: [String]) -> SlotReading {
        var slot: [String] = []
        for (index, word) in spoken.enumerated() where index == spoken.count - 1 || (index > 0 && heardSlotLeadWords.contains(spoken[index - 1])) {
            if word.count >= 3, word.allSatisfy(\.isLetter), !slot.contains(word) { slot.append(word) }
        }
        let appWords = Set(names.flatMap { name -> [String] in
            let tokens = RealtimeVoiceVerbs.foldedTokens(name.name)
            return tokens + [tokens.joined()]
        })
        let appKeys = Set(names.compactMap { name -> String? in
            let tokens = RealtimeVoiceVerbs.foldedTokens(name.name)
            return tokens.count == 1 && tokens[0].count >= 5 ? soundKey(tokens[0]) : nil
        })
        func isApp(_ word: String) -> Bool {
            appWords.contains(word) || (word.count >= 4 && !soundAlikeStopWords.contains(word) && appKeys.contains(soundKey(word)))
        }
        return SlotReading(
            logged: slot.filter { isApp($0) || !isEnglishWord($0) },
            unrecognised: slot.filter { word in
                !isApp(word) && !isEnglishWord(word) && !menuWords.contains { RealtimeVoiceVerbs.tokensMatch($0, word) }
            })
    }

    // MARK: The decision

    enum Outcome: String {
        case match
        case heardNamedMismatch
        case ambiguousApp
        /// The words name no app; the other checks decide.
        case noAppHeard
        /// A menu tool, no app heard, and the app slot holds an unknown word: ask.
        case appNameUnclear
        case transcriptMissing
        /// The words name the tool's app only by a guess, after a refusal this turn:
        /// the model retrying is not the user's answer.
        case unconfirmedRetry
    }

    struct Decision: Equatable {
        let outcome: Outcome
        let heardApps: [String]
        let tier: Tier?
        var heardSlot: [String] = []
        /// The result to return instead of calling the harness; nil proceeds.
        var refusalError: String? {
            switch outcome {
            case .heardNamedMismatch: return RealtimeHeardCheck.mismatchError
            case .ambiguousApp: return "ambiguousApp"
            case .unconfirmedRetry: return RealtimeHeardCheck.unconfirmedError
            case .appNameUnclear: return RealtimeHeardCheck.unavailableError
            case .match, .noAppHeard, .transcriptMissing: return nil
            }
        }
    }

    /// `transcript` nil or blank: nothing heard in time (see
    /// `refusesWithoutTranscript`). `menuWords` may legitimately fill the app slot.
    static func decide(transcript: String?, named: String, among names: [RealtimeVoiceVerbs.AppName],
                       afterHeardRefusal: Bool = false, toolName: String = "", menuWords: [String] = []) -> Decision {
        guard let transcript, !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return Decision(outcome: .transcriptMissing, heardApps: [], tier: nil)
        }
        let slot = readSlot(RealtimeVoiceVerbs.foldedTokens(transcript), among: names, menuWords: menuWords)
        var decision = decideHeard(transcript: transcript, named: named, among: names, afterHeardRefusal: afterHeardRefusal)
        if decision.outcome == .noAppHeard, RealtimeVoiceVerbs.isAppScopedMenuTool(toolName), !slot.unrecognised.isEmpty {
            decision = Decision(outcome: .appNameUnclear, heardApps: [], tier: nil)
        }
        decision.heardSlot = slot.logged
        return decision
    }

    private static func decideHeard(transcript: String, named: String, among names: [RealtimeVoiceVerbs.AppName],
                                    afterHeardRefusal: Bool) -> Decision {
        let heard = appsMentioned(in: transcript, among: names)
        let heardNames = heard.apps.map(RealtimeVoiceVerbs.displayName)
        guard let only = heard.apps.first else { return Decision(outcome: .noAppHeard, heardApps: [], tier: nil) }
        guard heard.apps.count == 1, !heard.ambiguousWord else {
            return Decision(outcome: .ambiguousApp, heardApps: heardNames, tier: heard.tier)
        }
        let samePath = { (url: URL) in url.standardizedFileURL.path == only.standardizedFileURL.path }
        let agrees: Bool
        switch RealtimeVoiceVerbs.resolveApp(named: named, among: names) {
        case .resolved(let url): agrees = samePath(url)
        case .ambiguous(let urls): agrees = urls.contains(where: samePath)
        case .notInstalled: agrees = false
        }
        if agrees, afterHeardRefusal, heard.tier?.confirmsARetry != true {
            return Decision(outcome: .unconfirmedRetry, heardApps: heardNames, tier: heard.tier)
        }
        return Decision(outcome: agrees ? .match : .heardNamedMismatch, heardApps: heardNames, tier: heard.tier)
    }

    /// Without a transcript, refuse a press and a launch of an app that isn't
    /// running; finds and focus changes are easily undone and keep other guards.
    static func refusesWithoutTranscript(toolName: String, namedAppIsRunning: Bool) -> Bool {
        toolName == RealtimeVoiceVerbs.pressMenuName || (toolName == RealtimeOpenAppTool.name && !namedAppIsRunning)
    }

    /// Every tool that names an app is checked.
    static func appliesTo(toolName: String) -> Bool {
        RealtimeVoiceVerbs.allToolNames.contains(toolName)
    }

    /// What the model is told instead of a harness answer (display names only).
    static func refusal(for decision: Decision, toolName: String, named: String, namedAppIsRunning: Bool = true) -> [String: Any]? {
        let shownNamed = UntrustedText(named).forDisplay
        switch decision.outcome {
        case .heardNamedMismatch:
            let heard = decision.heardApps.first ?? "another app"
            let said = decision.tier?.isTentative == true ? "may have said" : "said"
            return ["ok": false, "status": NSNull(), "error": mismatchError, "heard": heard, "named": named,
                    "message": "the owner \(said) \(heard), but this call names \(shownNamed). Nothing was opened, focused, "
                        + "searched or pressed. Ask the owner, briefly, whether they meant \(heard)."]
        case .unconfirmedRetry:
            let heard = decision.heardApps.first ?? "that app"
            return ["ok": false, "status": NSNull(), "error": unconfirmedError, "heard": heard, "named": named,
                    "message": "the owner may have said \(heard), but it was not heard clearly, and calling again is not their "
                        + "answer. Nothing was opened, focused, searched or pressed. Ask the owner, briefly, whether they meant "
                        + "\(heard), and wait for them to say so."]
        case .ambiguousApp:
            return ["ok": false, "status": NSNull(), "error": "ambiguousApp", "named": named, "candidates": decision.heardApps,
                    "message": "the owner's words fit more than one installed app: \(decision.heardApps.joined(separator: ", ")). "
                        + "Nothing was opened, focused, searched or pressed. Ask the owner which one they meant."]
        case .appNameUnclear:
            return ["ok": false, "status": NSNull(), "error": unavailableError, "named": named,
                    "message": "the owner's words name no installed app that could be recognised, so which app they meant "
                        + "is not confirmed. Nothing was searched or pressed. Ask them to say the app's name again."]
        case .transcriptMissing where refusesWithoutTranscript(toolName: toolName, namedAppIsRunning: namedAppIsRunning):
            let nothing = toolName == RealtimeOpenAppTool.name ? "Nothing was opened: \(shownNamed) is not running, and opening it would launch it."
                : "Nothing was pressed."
            return ["ok": false, "status": NSNull(), "error": unavailableError, "named": named,
                    "message": "the owner's words were not transcribed in time to confirm which app they meant. "
                        + nothing + " Ask them to say the app's name again."]
        default:
            return nil
        }
    }

    // MARK: Auto-focus

    /// When the user's words and the tool agree on one running app and the only
    /// problem is that another app is in front, Go focuses it and re-runs the
    /// call. Only full-name or slot evidence counts, and it never launches.
    static let autoFocusTiers: Set<Tier> = [.fullName, .slot]

    struct AutoFocusGate: Equatable {
        let triggered: Bool
        let reason: String
    }

    /// nil when the call did not come back `appMismatch`.
    static func autoFocusGate(heard: Decision?, dispatchError: String?, resolvedBundleIdentifier: String?,
                              namedAppIsRunning: Bool) -> AutoFocusGate? {
        guard dispatchError == "appMismatch" else { return nil }
        guard let heard, heard.outcome == .match else {
            return AutoFocusGate(triggered: false, reason: "heard:\(heard?.outcome.rawValue ?? "notChecked")")
        }
        guard let tier = heard.tier, autoFocusTiers.contains(tier) else {
            return AutoFocusGate(triggered: false, reason: "tier:\(heard.tier?.rawValue ?? "none")")
        }
        guard resolvedBundleIdentifier != nil else { return AutoFocusGate(triggered: false, reason: "unresolved") }
        guard namedAppIsRunning else { return AutoFocusGate(triggered: false, reason: "notRunning") }
        return AutoFocusGate(triggered: true, reason: "witnessesAgree")
    }

    /// The heard check's trace: app names and timings, never the sentence.
    static func traceObject(_ decision: Decision, named: String, transcriptArrivalMs: Int?, waitedMs: Int, refused: Bool) -> [String: Any] {
        ["refused": refused, "outcome": decision.outcome.rawValue, "heardApps": decision.heardApps, "tier": decision.tier?.rawValue ?? NSNull(),
         "named": named, "transcriptArrivalMs": transcriptArrivalMs ?? NSNull(), "waitedMs": waitedMs, "heardSlot": decision.heardSlot]
    }
}
