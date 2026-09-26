import AppKit
import Darwin
import Foundation

/// One saved step, kept by what it targets (never by screen position when a
/// name exists), so it can be found again on a later screen.
nonisolated struct GoRoutineStep: Codable, Equatable, Sendable {
    let instruction: String
    /// Bundle identifier of the app the step happened in.
    let app: String
    var controlRole: String? = nil
    var controlName: String? = nil
    var menuPath: [String]? = nil
    var fieldRole: String? = nil
    var fieldLabel: String? = nil
    /// Omitted for fields that look like they hold secrets; replay then asks.
    var typeText: String? = nil
    var pressReturn = false
    var launchApp: String? = nil
    /// A menu-bar icon or Dock item, by its name.
    var outsideName: String? = nil
    /// An unnamed on-screen target, described for the planner.
    var screenLabel: String? = nil
    var reveal = false
    var scrollDirection: String? = nil
    var opens = false
    var final = false
    var risk: GoRisk? = nil
    var keys: String? = nil
    var keyboard = false

    /// Words in a field's label that mean its contents may be secret.
    static let secretLabelWords = ["password", "passcode", "passphrase", "pin", "code", "otp", "token", "secret",
                                   "key", "cvv", "cvc", "security", "verification", "2fa", "card", "ssn"]

    static func isSecretLabel(_ label: String) -> Bool {
        let words = label.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
        return words.contains { secretLabelWords.contains($0) }
    }

    init(instruction: String, app: String) {
        self.instruction = instruction
        self.app = app
    }

    private enum CodingKeys: String, CodingKey {
        case instruction, app, controlRole, controlName, menuPath, fieldRole, fieldLabel, typeText, pressReturn, launchApp,
             outsideName, screenLabel, reveal, scrollDirection, opens, final, risk, keys, keyboard
    }

    /// Tolerant of fields a newer or older Go wrote or didn't: anything missing
    /// takes its default, so saved routines survive app updates.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        instruction = try c.decode(String.self, forKey: .instruction)
        app = try c.decode(String.self, forKey: .app)
        controlRole = try c.decodeIfPresent(String.self, forKey: .controlRole)
        controlName = try c.decodeIfPresent(String.self, forKey: .controlName)
        menuPath = try c.decodeIfPresent([String].self, forKey: .menuPath)
        fieldRole = try c.decodeIfPresent(String.self, forKey: .fieldRole)
        fieldLabel = try c.decodeIfPresent(String.self, forKey: .fieldLabel)
        typeText = try c.decodeIfPresent(String.self, forKey: .typeText)
        pressReturn = try c.decodeIfPresent(Bool.self, forKey: .pressReturn) ?? false
        launchApp = try c.decodeIfPresent(String.self, forKey: .launchApp)
        outsideName = try c.decodeIfPresent(String.self, forKey: .outsideName)
        screenLabel = try c.decodeIfPresent(String.self, forKey: .screenLabel)
        reveal = try c.decodeIfPresent(Bool.self, forKey: .reveal) ?? false
        scrollDirection = try c.decodeIfPresent(String.self, forKey: .scrollDirection)
        opens = try c.decodeIfPresent(Bool.self, forKey: .opens) ?? false
        final = try c.decodeIfPresent(Bool.self, forKey: .final) ?? false
        risk = try? c.decodeIfPresent(GoRisk.self, forKey: .risk)
        keys = try c.decodeIfPresent(String.self, forKey: .keys)
        keyboard = try c.decodeIfPresent(Bool.self, forKey: .keyboard) ?? false
    }

    init(_ step: GoWalkthroughStep) {
        instruction = step.instruction
        app = step.app
        controlRole = step.control?.role
        controlName = step.control?.name
        menuPath = step.menu?.path
        fieldRole = step.field?.role
        fieldLabel = step.field?.label
        if let text = step.typeText, !Self.isSecretLabel(step.field?.label ?? ""), !Self.isSecretLabel(step.screenLabel ?? "") {
            typeText = text
        }
        pressReturn = step.pressReturn
        launchApp = step.launchApp
        outsideName = step.outsideName
        if step.screenRect != nil, step.outsideName == nil { screenLabel = step.screenLabel }
        reveal = step.reveal
        scrollDirection = step.scrollDirection
        opens = step.opens
        final = step.final
        risk = step.risk
        keys = step.keys
        keyboard = step.keyboard
        // Keyboard typing has no field label to judge; Go never types into password fields.
        if step.keyboard { typeText = step.typeText }
    }

    /// What the step acts on, for matching a finished step to the routine.
    var targetKey: String {
        if keyboard { return "keyboard:\(keys ?? ""):\(typeText ?? "")" }
        if reveal { return "reveal" }
        if let launchApp { return "launch:" + launchApp.lowercased() }
        if let outsideName { return "outside:" + outsideName }
        if let menuPath { return "menu:" + menuPath.joined(separator: ">") }
        if let fieldLabel { return "field:\(fieldRole ?? ""):\(fieldLabel)" }
        if let controlName { return "control:\(controlRole ?? ""):\(controlName)" }
        return "screen"
    }

    /// A short description for the planner when the step can't be found locally.
    var hint: String {
        var parts = ["Instruction: \(instruction)"]
        if let launchApp { parts.append("opens the app \(launchApp)") }
        if let outsideName { parts.append("target: \(outsideName) (menu bar or Dock)") }
        if let menuPath { parts.append("menu: " + menuPath.joined(separator: " > ")) }
        if let fieldLabel { parts.append("field: \(fieldLabel)") }
        if let controlName { parts.append("control: \(controlName)") }
        if let screenLabel { parts.append("target: \(screenLabel)") }
        if let typeText { parts.append("types: \(typeText)") }
        if let keys { parts.append("presses: \(keys)") }
        return parts.joined(separator: "; ")
    }
}

nonisolated struct GoRoutine: Codable, Equatable, Sendable {
    let id: UUID
    var name: String
    /// The task the routine was recorded for, in the owner's words.
    var goal: String
    var steps: [GoRoutineStep]
    let created: Date

    /// Names compare without case, punctuation, small filler words or a trailing "routine".
    static func key(_ name: String) -> String {
        var words = RealtimeOpenAppTool.normalisedAnswer(name).split(separator: " ").map(String.init)
        words.removeAll { ["my", "the", "a", "an"].contains($0) }
        while let last = words.last, ["routine", "workflow"].contains(last) { words.removeLast() }
        return words.joined(separator: " ")
    }

    /// The saved name a spoken phrase means. Speech-to-text writes names in
    /// its own way ("You Tube" for YouTube, a letter or two off), so spaces are
    /// ignored and, when `fuzzy`, a small spelling difference is allowed if
    /// exactly one name is that close.
    static func match(_ phrase: String, among names: [String], fuzzy: Bool) -> String? {
        let key = key(phrase)
        guard !key.isEmpty else { return nil }
        if let exact = names.first(where: { Self.key($0) == key }) { return exact }
        let compact = key.replacingOccurrences(of: " ", with: "")
        let compacted = names.filter { Self.key($0).replacingOccurrences(of: " ", with: "") == compact }
        if compacted.count == 1 { return compacted[0] }
        guard fuzzy, compact.count >= 5 else { return nil }
        let allowed = max(1, compact.count / 5)
        let close = names.filter {
            editDistance(Self.key($0).replacingOccurrences(of: " ", with: ""), compact) <= allowed
        }
        return close.count == 1 ? close[0] : nil
    }

    static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        guard !a.isEmpty else { return b.count }
        guard !b.isEmpty else { return a.count }
        var previous = Array(0...b.count)
        for i in 1...a.count {
            var current = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            previous = current
        }
        return previous[b.count]
    }
}

/// Saved routines, in `~/Library/Application Support/Go/routines.json` (owner-only).
@MainActor
final class GoRoutineStore {
    nonisolated static let defaultURL = URL.applicationSupportDirectory
        .appendingPathComponent("Go", isDirectory: true).appendingPathComponent("routines.json")
    private let url: URL
    private(set) var routines: [GoRoutine] = []
    private var loadFailed = false

    init(url: URL = GoRoutineStore.defaultURL) {
        self.url = url
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        guard let data = try? Data(contentsOf: url) else { loadFailed = true; return }
        if let decoded = Self.decode(data) {
            routines = decoded
        } else {
            // Unreadable as a whole: keep it as a backup and start a fresh file,
            // rather than refusing every save from now on.
            let backup = url.deletingLastPathComponent()
                .appendingPathComponent("routines-unreadable-\(Int(Date().timeIntervalSince1970)).json")
            if (try? FileManager.default.moveItem(at: url, to: backup)) == nil { loadFailed = true }
        }
    }

    /// Each routine separately, so one damaged entry doesn't lose the rest.
    /// Nil when the file isn't a list at all.
    nonisolated static func decode(_ data: Data) -> [GoRoutine]? {
        guard let list = (try? JSONSerialization.jsonObject(with: data)) as? [Any] else { return nil }
        return list.compactMap { entry in
            guard let entryData = try? JSONSerialization.data(withJSONObject: entry) else { return nil }
            return try? JSONDecoder().decode(GoRoutine.self, from: entryData)
        }
    }

    func routine(named name: String) -> GoRoutine? {
        guard let match = GoRoutine.match(name, among: routines.map(\.name), fuzzy: true) else { return nil }
        return routines.first { $0.name == match }
    }

    /// Saves (or replaces, by name) a routine. False when it could not be written.
    func save(name: String, goal: String, steps: [GoRoutineStep]) -> Bool {
        let key = GoRoutine.key(name)
        guard !loadFailed, !key.isEmpty, !steps.isEmpty else { return false }
        var next = routines.filter { GoRoutine.key($0.name) != key }
        next.append(GoRoutine(id: UUID(), name: name, goal: goal, steps: steps, created: Date()))
        return write(next)
    }

    func delete(named name: String) -> Bool {
        let key = GoRoutine.key(name)
        guard !loadFailed, routines.contains(where: { GoRoutine.key($0.name) == key }) else { return false }
        return write(routines.filter { GoRoutine.key($0.name) != key })
    }

    func deleteAll() -> Bool {
        guard !loadFailed else { return false }
        return write([])
    }

    private func write(_ next: [GoRoutine]) -> Bool {
        do {
            let directory = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let temporary = directory.appendingPathComponent(".routines-\(UUID().uuidString).json")
            defer { try? FileManager.default.removeItem(at: temporary) }
            guard FileManager.default.createFile(atPath: temporary.path, contents: try JSONEncoder().encode(next),
                                                 attributes: [.posixPermissions: 0o600]),
                  rename(temporary.path, url.path) == 0 else { return false }
            routines = next
            return true
        } catch { return false }
    }
}

/// Routine requests in the owner's words. Run, walk and delete only match a
/// routine that exists, so ordinary requests pass through untouched.
nonisolated enum GoRoutineIntent: Equatable, Sendable {
    /// `explicit`: the words said "routine", "workflow" or "steps". Otherwise
    /// ("save this as X") it is only a routine right after a finished walkthrough.
    case save(name: String, explicit: Bool)
    case run(name: String)
    case walk(name: String)
    case delete(name: String)
    /// "Delete all my routines": Go asks for a yes first.
    case deleteAll
    case list
    /// "Run the X routine" where no routine is called anything like X.
    case unknown(name: String)

    /// For logs: the kind of request, never the name.
    var kind: String {
        switch self {
        case .save: return "save"
        case .run: return "run"
        case .walk: return "walk"
        case .delete: return "delete"
        case .deleteAll: return "deleteAll"
        case .list: return "list"
        case .unknown: return "unknown"
        }
    }

    private static let savePattern = try! NSRegularExpression(
        pattern: #"\b(?:save|remember)\s+(?:(this|that|it|these steps|those steps|the steps|what we just did)\s+)?(?:(?:as\s+a\s+)?(routine|workflow)\s+)?(?:as|called|named)\s+(.+)$"#,
        options: [.caseInsensitive])
    /// "Save this as PDF" is a task, not a routine name.
    static let fileFormatNames: Set<String> = ["pdf", "png", "jpg", "jpeg", "heic", "gif", "tiff", "csv", "txt", "rtf", "html",
                                               "doc", "docx", "xls", "xlsx", "ppt", "pptx", "pages", "numbers", "keynote",
                                               "image", "picture", "file", "copy", "draft", "template", "text", "document"]
    private static let runLeads = ["run", "do", "start", "play", "go through", "replay", "repeat"]
    private static let walkLeads = ["walk me through", "guide me through", "show me", "teach me", "help me with", "take me through"]
    private static let deleteLeads = ["delete", "remove", "forget"]

    /// `recent`: the routine just saved or used, which "run it" or "do that
    /// routine" refers to.
    static func parse(_ heard: String?, names: [String], recent: String? = nil) -> GoRoutineIntent? {
        guard let heard else { return nil }
        let raw = heard.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = RealtimeOpenAppTool.normalisedAnswer(raw)
        guard !text.isEmpty else { return nil }
        if let match = savePattern.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)),
           let range = Range(match.range(at: 3), in: raw) {
            let name = cleanName(String(raw[range]))
            let object = Range(match.range(at: 1), in: raw).map { raw[$0].lowercased() } ?? ""
            let explicit = Range(match.range(at: 2), in: raw) != nil || object.contains("steps") || object.contains("what we")
            var nameWords = GoRoutine.key(name).split(separator: " ").map(String.init)
            if nameWords.first == "an" { nameWords.removeFirst() }
            if !nameWords.isEmpty, explicit || !(nameWords.count == 1 && fileFormatNames.contains(nameWords[0])) {
                return .save(name: name, explicit: explicit)
            }
        }
        let padded = " " + text + " "
        let spoken = Set(text.split(separator: " ").map(String.init))
        // Requests are recognised by meaning (routines + what to do with them),
        // not by exact wording, so a rephrasing or a misheard word still lands.
        let aboutRoutines = !spoken.isDisjoint(with: ["routine", "routines", "workflow", "workflows"])
        let asksToDelete = deleteLeads.contains { padded.contains(" " + $0 + " ") } || spoken.contains("clear")
        // The lead can come anywhere ("can you run X for me"); what follows it
        // must be a saved routine's name, so other requests never match.
        func named(after leads: [String]) -> String? {
            for lead in leads {
                var searchStart = padded.startIndex
                while let range = padded.range(of: " " + lead + " ", range: searchStart..<padded.endIndex) {
                    if let name = GoRoutine.match(trimmingFiller(String(padded[range.upperBound...])), among: names, fuzzy: true) {
                        return name
                    }
                    searchStart = padded.index(after: range.lowerBound)
                }
            }
            return nil
        }
        if let name = named(after: deleteLeads) { return .delete(name: name) }
        if aboutRoutines, asksToDelete,
           !spoken.isDisjoint(with: ["all", "every", "everything"]) || spoken.contains("routines") || spoken.contains("workflows") {
            return .deleteAll
        }
        if ["what routines", "which routines", "list my routines", "list routines", "my routines", "show my routines",
            "saved routines"].contains(where: { padded.contains(" " + $0 + " ") }) { return .list }
        // "Run it", "do that routine", "walk me through it": the routine just saved or used.
        if let recent, names.contains(recent) {
            let references: Set<String> = ["it", "that", "this", "the routine", "that routine", "this routine", "that one",
                                           "this one", "it again", "that again", "the same", "the same thing"]
            // "Do it for me" is the existing take-over request, so after "do" (and the
            // other general verbs) only "that routine" / "the routine" refers here.
            let pronounLeads: Set<String> = ["run", "replay", "repeat", "walk me through", "take me through", "guide me through"]
            func refers(after leads: [String]) -> Bool {
                leads.contains { lead in
                    guard let range = padded.range(of: " " + lead + " ") else { return false }
                    let rest = String(padded[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                    let said = rest.contains("routine") ? rest : trimmingFiller(rest)
                    guard references.contains(said) || references.contains(trimmingFiller(rest)) else { return false }
                    return pronounLeads.contains(lead) || rest.contains("routine")
                }
            }
            if refers(after: walkLeads) { return .walk(name: recent) }
            if refers(after: runLeads) { return .run(name: recent) }
        }
        if let name = named(after: walkLeads) { return .walk(name: name) }
        if let name = named(after: runLeads) { return .run(name: name) }
        // Just the name ("Go, morning setup") runs it.
        var words = trimmingFiller(text).split(separator: " ").map(String.init)
        while let first = words.first, ["go", "hey", "please", "okay", "ok"].contains(first) { words.removeFirst() }
        if let name = GoRoutine.match(words.joined(separator: " "), among: names, fuzzy: false) { return .run(name: name) }
        // "<name> routine" anywhere, even if the words before it were misheard.
        let spokenNames = names.filter { name in
            let key = GoRoutine.key(name)
            return !key.isEmpty && padded.contains(" " + key + " routine ")
        }
        if spokenNames.count == 1 { return .run(name: spokenNames[0]) }
        // A question about routines ("what routines do I have saved?", "do I have
        // any routines?") lists them, however it is worded.
        if aboutRoutines, !asksToDelete,
           !spoken.isDisjoint(with: ["what", "which", "list", "show", "tell", "have", "got", "any", "saved", "names", "all"]) {
            return .list
        }
        // The owner clearly asked for a routine, just not one that exists.
        if padded.contains(" routine ") {
            for lead in deleteLeads + walkLeads + runLeads {
                guard let range = padded.range(of: " " + lead + " ") else { continue }
                var asked = trimmingFiller(String(padded[range.upperBound...])).split(separator: " ").map(String.init)
                while let first = asked.first, ["my", "the", "a", "an"].contains(first) { asked.removeFirst() }
                if !asked.isEmpty { return .unknown(name: asked.joined(separator: " ")) }
            }
        }
        return nil
    }

    /// Polite endings after a routine's name: "run X for me please".
    static func trimmingFiller(_ text: String) -> String {
        var words = text.split(separator: " ").map(String.init)
        let trailing: Set<String> = ["for", "me", "please", "now", "again", "thanks", "thank", "you", "routine", "workflow"]
        while let last = words.last, trailing.contains(last) { words.removeLast() }
        return words.joined(separator: " ")
    }

    static func cleanName(_ text: String) -> String {
        var name = text.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        for suffix in [" please", " thanks", " thank you"] where name.lowercased().hasSuffix(suffix) {
            name = String(name.dropLast(suffix.count))
        }
        return String(name.prefix(60)).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Turning a saved step into a proposal on the current screen, locally.
nonisolated enum GoRoutineReplay {
    /// The proposal for `step` if its target is on this screen, else nil (the
    /// planner then works out how to get there).
    static func proposal(for step: GoRoutineStep, in observation: GoObservation) -> GoStepProposal? {
        let kind: GoStepProposal.Kind = step.final ? .point : .step
        func make(_ id: String, typeText: String? = nil) -> GoStepProposal {
            var proposal = GoStepProposal(kind: kind, instruction: step.instruction, targetID: id, expected: nil)
            proposal.typeText = typeText
            proposal.pressReturn = typeText != nil && step.pressReturn
            proposal.open = step.opens
            proposal.risk = step.risk
            return proposal
        }
        if let app = step.launchApp {
            var proposal = GoStepProposal(kind: .launch, instruction: step.instruction, targetID: nil, expected: nil)
            proposal.app = app
            return proposal
        }
        if let name = step.outsideName, let control = observation.systemControls.first(where: { $0.name == name }) {
            return make(control.id)
        }
        guard step.app == observation.app else { return nil }
        if step.keyboard {
            var proposal = GoStepProposal(kind: .step, instruction: step.instruction, targetID: "keyboard", expected: nil)
            proposal.typeText = step.typeText
            proposal.keys = step.keys
            proposal.risk = step.risk
            return proposal
        }
        if step.reveal {
            var proposal = GoStepProposal(kind: .reveal, instruction: step.instruction, targetID: nil, expected: nil)
            proposal.scroll = step.scrollDirection
            return proposal
        }
        if let path = step.menuPath, let menu = observation.menus.first(where: { $0.path == path }) {
            return make(menu.id)
        }
        if let label = step.fieldLabel {
            let fields = observation.fields.filter { $0.label == label && $0.role == (step.fieldRole ?? $0.role) }
            guard fields.count == 1, let text = step.typeText else { return nil }
            return make(fields[0].id, typeText: text)
        }
        if let name = step.controlName, let role = step.controlRole {
            let matches = observation.matches(role: role, name: name)
            return matches.count == 1 ? make(matches[0].id) : nil
        }
        return nil
    }
}
