import Foundation

/// Owner speech, not a model tool call, must authorize computer changes.
/// Conservative English command recognition: uncertain requests stay read-only.
nonisolated enum GoVoiceActionPolicy {
    static let refusal = #"{"ok":false,"error":"guidanceOnly","message":"Give one short instruction. The owner has not asked Go to perform an action. Do not retry with another action tool."}"#

    static func allowsActions(heard: String?) -> Bool {
        guard let heard else { return false }
        var text = RealtimeOpenAppTool.normalisedAnswer(heard)
        let padded = " " + text + " "
        if asksGoToHelpDo(text) { return true }
        let guidance = ["how", "where", "why", "explain", "guide", "walk", "teach", "show me", "help me understand",
                        "help me learn", "don t", "do not", "dont", "never", "stop", "cancel", "instead", "without",
                        "should", "could i", "can i"]
        guard !guidance.contains(where: { padded.contains(" " + $0 + " ") }) else { return false }
        text = strippingLeadIns(text)
        return actions.contains { text.hasPrefix($0 + " ") }
    }

    /// Removes what people say before the task itself: "okay, now please…",
    /// "I want you to…", "I need to…", "can you help me…", "let's…".
    static func strippingLeadIns(_ normalised: String) -> String {
        var text = normalised
        for _ in 0..<8 {
            guard let prefix = leadIns.first(where: { text.hasPrefix($0 + " ") }) else { break }
            text.removeFirst(prefix.count + 1)
        }
        return text
    }

    /// "Can you help me <task>" asks Go to do the task. Wording about learning
    /// it ("how", "show", "teach", "explain", "understand") still only guides.
    static func asksGoToHelpDo(_ normalised: String) -> Bool {
        let padded = " " + normalised + " "
        let learning = [" how ", " show ", " teach ", " explain ", " understand ", " learn ", " walk ", " guide ", " don t ", " do not ", " dont ", " not "]
        guard !learning.contains(where: { padded.contains($0) }) else { return false }
        var text = normalised
        for prefix in ["hey go ", "go ", "okay ", "ok ", "so ", "now "] where text.hasPrefix(prefix) { text.removeFirst(prefix.count) }
        let asks = ["can you please help me ", "could you please help me ", "can you help me ", "could you help me ",
                    "would you help me ", "will you help me ", "can you just help me "]
        guard let ask = asks.first(where: { text.hasPrefix($0) }) else { return false }
        return text.count > ask.count + 2
    }

    /// Longest first, so "go ahead and" wins over "go".
    static let leadIns = ["can you please", "could you please", "would you please", "i want you to", "i need you to",
                          "i d like you to", "id like you to", "i would like you to", "go ahead and", "hey go", "all right",
                          "i want to", "i need to", "i d like to", "id like to", "i would like to", "i m trying to",
                          "im trying to", "i am trying to", "we need to", "we have to", "i have to", "i gotta",
                          "help me", "alright", "okay", "ok", "hey", "so", "now", "and", "then", "just", "please",
                          "can you", "could you", "would you", "will you", "you can", "let s", "lets", "go"]
    /// Verbs that ask Go to do something on screen. The safety kernel still
    /// decides every action; risky ones (delete, send) ask or are refused.
    static let actions = ["open", "launch", "focus", "switch", "click", "press", "select", "create", "make", "set", "change",
                          "turn", "close", "type", "write", "add", "rename", "move", "copy", "paste", "save", "run", "search",
                          "go to", "navigate", "play", "pause", "download", "enable", "disable", "start", "put", "fill", "enter",
                          "insert", "sort", "new", "delete", "remove", "send", "reply", "hide", "minimize", "scroll", "upload",
                          "attach", "restart", "quit", "refresh", "reload", "undo", "redo", "print", "share", "duplicate",
                          "archive", "mark", "star", "schedule", "mute", "unmute", "bookmark", "pin", "log", "sign",
                          // Working with data and documents.
                          "figure", "work", "calculate", "compute", "sum", "total", "average", "compare", "chart", "plot",
                          "graph", "analyze", "analyse", "count", "filter", "format", "fix", "update", "edit", "build",
                          "organize", "organise", "clean", "convert", "export", "import", "merge", "split", "apply",
                          "resize", "crop", "record", "check", "connect", "join", "follow", "subscribe", "get", "put",
                          "draw", "sketch", "list", "summarize", "summarise", "translate", "highlight", "underline", "bold"]

    /// A second guard at the harness boundary also catches implicit focus and
    /// future action verbs. The existing safety kernel still checks allowed calls.
    static func guardedAnswer(allowActions: Bool, answer: @escaping @Sendable (String) -> String) -> @Sendable (String) -> String {
        { line in
            if !allowActions {
                let object = line.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
                let reads: Set<String> = ["ping", "snapshot", "menus", "windows", "look", "status", "highlight"]
                guard let verb = object?["verb"] as? String, reads.contains(verb) else { return refusal }
            }
            return answer(line)
        }
    }
}
