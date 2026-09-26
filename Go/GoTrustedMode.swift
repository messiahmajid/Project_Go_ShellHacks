import Foundation
import SwiftUI

/// The owner's choice to let Go act without confirmation cards, except for
/// actions the safety kernel flags as destructive (delete, remove, trash, send,
/// quit, reset…). Password fields and irreversible actions (erase, empty trash,
/// buy, pay) are refused before this setting is ever consulted.
nonisolated enum GoTrustedMode {
    static let defaultsKey = "goTrustedMode"
    static var isOn: Bool { UserDefaults.standard.bool(forKey: defaultsKey) }

    /// Whether a confirmation question may be approved without a card. Only
    /// questions reach here: refusals (secure fields, irreversible actions) never do.
    static func approves(destructive: Bool, isOn: Bool = GoTrustedMode.isOn) -> Bool { isOn && !destructive }
}

/// Panel switch for trusted mode.
struct GoTrustedModeToggle: View {
    @AppStorage(GoTrustedMode.defaultsKey) private var trusted = false

    var body: some View {
        GoPanelSwitchRow(
            icon: "checkmark.shield.fill",
            tint: Color(hex: "#8E7CF0"),
            title: "Trusted mode",
            subtitle: "Go acts without asking, except deleting and similar. Passwords, erasing and purchases are always blocked.",
            isOn: $trusted
        )
    }
}

/// Text as it should be read aloud; the bubble keeps the exact text. Times read
/// naturally ("2:00 PM" → "2 PM"), shortcut symbols become words ("⌘⇧B" →
/// "command shift B"), and formulas, code and paths, which a voice turns into
/// noise, become "the formula shown" or "the text shown".
nonisolated enum GoSpeechText {
    private static let keySymbols: [(String, String)] = [
        ("⌘", "command "), ("⇧", "shift "), ("⌥", "option "), ("⌃", "control "), ("↩", " return"), ("⏎", " return"),
        ("⌫", " delete"), ("⌦", " forward delete"), ("⇥", " tab"), ("⎋", " escape"),
        ("←", " left arrow"), ("→", " right arrow"), ("↑", " up arrow"), ("↓", " down arrow"),
    ]
    private static let codeSymbols = Set("=()[]{}<>+*/\\$!;:|^%&#@~_")

    /// Formula, code, a path or a web address: symbols a voice can't say usefully.
    static func isUnspeakable(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 2 else { return false }
        if trimmed.hasPrefix("=") || trimmed.contains("://") { return true }
        let symbols = trimmed.filter { codeSymbols.contains($0) }.count
        return symbols >= 3 || (trimmed.count >= 6 && Double(symbols) / Double(trimmed.count) >= 0.3)
    }

    private static func replacingUnspeakable(_ text: String, pattern: String) -> String {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return text }
        var result = text
        for match in expression.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let whole = Range(match.range, in: result), let inner = Range(match.range(at: 1), in: result) else { continue }
            let content = String(result[inner])
            guard isUnspeakable(content) else { continue }
            result.replaceSubrange(whole, with: content.trimmingCharacters(in: .whitespaces).hasPrefix("=") ? "the formula shown" : "the text shown")
        }
        return result
    }

    static func spoken(_ text: String) -> String {
        var result = replacingUnspeakable(text, pattern: "\u{201C}([^\u{201D}]*)\u{201D}")
        result = replacingUnspeakable(result, pattern: "\"([^\"]*)\"")
        // Shortcut symbols first, so "(⌘⇧S)" reads as words, not as code.
        for (symbol, words) in keySymbols { result = result.replacingOccurrences(of: symbol, with: words) }
        // Unquoted runs of symbols (a formula with quotes of its own inside).
        result = result.split(separator: " ", omittingEmptySubsequences: false).map { word in
            word.count >= 6 && isUnspeakable(String(word)) ? "the text shown" : String(word)
        }.joined(separator: " ")
        result = result.replacingOccurrences(of: "…", with: ".")
        result = result.replacingOccurrences(of: #" {2,}"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\( "#, with: "(", options: .regularExpression)
            .replacingOccurrences(of: #" \)"#, with: ")", options: .regularExpression)
        // "a.m." / "p.m." → "am" / "pm" first, so a sentence's own full stop is never eaten.
        result = result.replacingOccurrences(of: #"\b([AaPp])\.\s?[Mm]\."#, with: "$1m", options: .regularExpression)
        // 2:00 PM, 2:00pm → 2 PM
        result = result.replacingOccurrences(of: #"\b(\d{1,2}):00\s*([AaPp])[Mm]\b"#, with: "$1 $2M", options: .regularExpression)
        // 2:30pm → 2:30 PM, 3pm → 3 PM
        result = result.replacingOccurrences(of: #"\b(\d{1,2}(?::\d{2})?)\s*([AaPp])[Mm]\b"#, with: "$1 $2M", options: .regularExpression)
        return result.replacingOccurrences(of: " aM", with: " AM").replacingOccurrences(of: " pM", with: " PM")
    }
}
