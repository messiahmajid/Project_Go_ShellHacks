import Foundation

/// Decides locally, from the owner's own words, that a turn asks to be guided.
/// Go, not the voice model, decides whether a walkthrough starts: a guidance
/// request always becomes one step, pointed at, and watched.
nonisolated enum GoGuidanceIntent: Equatable, Sendable {
    /// A new task in the owner's words, e.g. "creating a folder in Finder".
    case newTask(String)
    /// Guidance for the saved goal: "walk me through it", "what next?".
    case continueGoal
    /// "Do it for me": Go performs the saved goal's remaining steps itself.
    case doForMe
    /// "Create a folder called test for me": a new task Go performs itself.
    case doTaskForMe(String)

    /// Explicit requests to be guided or taught, and questions about the screen.
    /// Statements and commands ("figure out…", "I need a chart…") are not
    /// here: Go carries those out itself (see `command`).
    private static let triggers = [
        "walk me through", "show me how to", "show me how", "guide me through", "guide me",
        "teach me how to", "teach me to", "help me understand", "help me learn", "how do i", "how can i", "how would i",
        "how should i", "how do you", "how to", "show me", "where do i", "where can i",
        // Questions about what is on screen: answered by pointing, not by talking.
        "can you see", "do you see", "can you find", "is there", "are there", "where is", "where s", "wheres",
        "where are", "point to", "point at", "point me to", "highlight", "which one is", "find"
    ]
    private static let continuations = [
        "whats next", "what s next", "what next", "what now", "what do i do next", "what do i do now",
        "next step", "keep going", "continue", "now what", "i did it", "i did that", "i clicked it", "i m done", "im done"
    ]
    /// Words that carry no task of their own: "walk me through it" continues.
    private static let filler: Set<String> = [
        "it", "this", "that", "these", "those", "do", "the", "a", "an", "to", "with", "through", "now",
        "next", "step", "steps", "please", "go", "again", "here", "there", "one", "thing", "out", "for", "me"
    ]

    static func parse(_ heard: String?) -> GoGuidanceIntent? {
        guard let heard else { return nil }
        let text = RealtimeOpenAppTool.normalisedAnswer(heard)
        guard !text.isEmpty else { return nil }
        let padded = " " + text + " "
        if padded.contains(" stop ") || padded.contains(" cancel ") { return nil }
        if let takeover = takeover(padded) { return takeover }
        // "Can you help me <task>": Go does it.
        if GoVoiceActionPolicy.asksGoToHelpDo(text) {
            var words = text.split(separator: " ").map(String.init)
            if let index = words.firstIndex(of: "help"), index + 1 < words.count, words[index + 1] == "me" {
                words.removeSubrange(0...(index + 1))
            }
            while let first = words.first, ["to", "with", "please"].contains(first) { words.removeFirst() }
            var task = words.joined(separator: " ")
            task = shortened(task)
            if !task.isEmpty { return .doTaskForMe(task) }
        }
        if continuations.contains(where: { padded.contains(" " + $0 + " ") }) { return .continueGoal }
        if text == "help me" || text == "help" || text == "help me out" { return .continueGoal }
        guard let trigger = triggers.first(where: { padded.contains(" " + $0 + " ") }),
              let range = padded.range(of: " " + trigger + " ") else { return command(heard) }
        let remainder = padded[range.upperBound...].split(separator: " ").map(String.init)
        let meaningful = remainder.filter { !filler.contains($0) }
        guard !meaningful.isEmpty else { return .continueGoal }
        var task = remainder.drop { filler.contains($0) }.joined(separator: " ")
        task = shortened(task)
        return .newTask(task)
    }

    private static let takeoverPhrases = ["do it for me", "you do it", "just do it", "do the rest", "finish it for me",
                                          "take over", "do this for me", "do that for me", "can you do it", "do it yourself"]
    private static let negations = [" don t ", " do not ", " dont ", " never ", " not "]

    /// Owner's words asking Go to act. A negation ("don't do it for me") never is.
    private static func takeover(_ padded: String) -> GoGuidanceIntent? {
        guard !negations.contains(where: { padded.contains($0) }) else { return nil }
        if takeoverPhrases.contains(where: { padded.contains(" " + $0 + " ") }) { return .doForMe }
        guard padded.hasSuffix(" for me ") else { return nil }
        var words = padded.split(separator: " ").map(String.init)
        words.removeLast(2)
        let lead: Set<String> = ["can", "could", "would", "will", "you", "please", "go", "hey", "just"]
        while let first = words.first, lead.contains(first) { words.removeFirst() }
        guard words.contains(where: { !filler.contains($0) }) else { return .doForMe }
        var task = words.joined(separator: " ")
        task = shortened(task)
        return .doTaskForMe(task)
    }

    /// A yes or no to one of Go's own questions; nil when the reply is neither.
    static func yesNo(_ heard: String?) -> Bool? {
        guard let heard else { return nil }
        let padded = " " + RealtimeOpenAppTool.normalisedAnswer(heard) + " "
        let no = [" no ", " nope ", " don t ", " do not ", " dont ", " stop ", " cancel ", " wait ", " not now ", " never mind "]
        let yes = [" yes ", " yeah ", " yep ", " yup ", " sure ", " go ahead ", " do it ", " okay ", " ok ", " please ", " confirm ", " sounds good "]
        if no.contains(where: { padded.contains($0) }) { return false }
        if yes.contains(where: { padded.contains($0) }) { return true }
        return nil
    }

    /// A direct command ("open the photo called FT", "click Share") is a task Go
    /// performs itself through its planner, whatever app it concerns.
    private static func command(_ heard: String) -> GoGuidanceIntent? {
        guard GoVoiceActionPolicy.allowsActions(heard: heard) else { return nil }
        var task = GoVoiceActionPolicy.strippingLeadIns(RealtimeOpenAppTool.normalisedAnswer(heard))
        guard !task.isEmpty else { return nil }
        task = shortened(task)
        return .doTaskForMe(task)
    }

    /// Goal tasks are at most 80 characters: cut at a word boundary. The owner's
    /// full words stay in the goal's raw text, which the planner reads.
    static func shortened(_ task: String) -> String {
        guard task.count > 80 else { return task }
        let prefix = String(task.prefix(80))
        return prefix.lastIndex(of: " ").map { String(prefix[..<$0]) } ?? prefix
    }

    /// The goal record for a new task. The whole utterance is its own source quote.
    static func goalRequest(task: String, heard: String) -> GoGoalRequest {
        GoGoalRequest(operation: .set, sourceQuote: heard, task: task)
    }
}
