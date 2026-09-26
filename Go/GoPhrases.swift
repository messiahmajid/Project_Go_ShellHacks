import Foundation

/// Short, warm spoken cues. Each kind rotates so Go never says the same thing
/// twice in a row, and none of them adds more than a couple of words.
nonisolated struct GoPhrases: Sendable {
    enum Kind: Sendable { case stepDone, startForMe, offTrack, goBack, thinking }

    private static let bank: [Kind: [String]] = [
        .stepDone: ["Nice.", "Perfect.", "Great.", "That's it.", "Lovely."],
        .startForMe: ["Sure, on it.", "Okay, I'll take it from here.", "Got it, doing that now.", "On it."],
        .offTrack: ["Not quite.", "Almost, not that one.", "Close, but not that one."],
        .goBack: ["Let's go back.", "Let's try that again."],
        .thinking: ["One sec…", "Let me look.", "Checking…", "Give me a second."],
    ]
    private var next: [Kind: Int] = [:]

    mutating func say(_ kind: Kind) -> String {
        let options = Self.bank[kind] ?? [""]
        let index = next[kind, default: 0]
        next[kind] = (index + 1) % options.count
        return options[index % options.count]
    }
}
