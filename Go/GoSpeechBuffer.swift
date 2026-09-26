import Foundation

/// Releases complete sentences as transcript deltas arrive. The final fragment
/// is released once, when the model turn ends. Never split inside a decimal.
nonisolated struct GoSpeechBuffer {
    private var pending = ""

    mutating func append(_ delta: String) -> [String] {
        pending += delta
        var ready: [String] = []
        while let end = sentenceEnd() {
            let sentence = String(pending[..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
            pending = String(pending[end...])
            if !sentence.isEmpty { ready.append(sentence) }
        }
        return ready
    }

    mutating func finish() -> String? {
        let tail = pending.trimmingCharacters(in: .whitespacesAndNewlines)
        pending = ""
        return tail.isEmpty ? nil : tail
    }

    private func sentenceEnd() -> String.Index? {
        for index in pending.indices {
            let character = pending[index]
            let next = pending.index(after: index)
            if character.isNewline || character == "!" || character == "?" { return next }
            if ".!?".contains(character), next < pending.endIndex, pending[next].isWhitespace {
                return next
            }
        }
        return nil
    }
}
