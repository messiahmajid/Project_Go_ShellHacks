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
        Toggle(isOn: $trusted) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Trusted mode").font(.system(size: 12, weight: .semibold))
                Text("Go acts without asking, except deleting and similar. Passwords, erasing and purchases are always blocked.")
                    .font(.system(size: 10)).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .toggleStyle(.switch)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}

/// Text as it should be read aloud: "2:00 PM" → "2 PM", "2:30pm" → "2:30 PM".
/// Display text is left untouched.
nonisolated enum GoSpeechText {
    static func spoken(_ text: String) -> String {
        var result = text
        // "a.m." / "p.m." → "am" / "pm" first, so a sentence's own full stop is never eaten.
        result = result.replacingOccurrences(of: #"\b([AaPp])\.\s?[Mm]\."#, with: "$1m", options: .regularExpression)
        // 2:00 PM, 2:00pm → 2 PM
        result = result.replacingOccurrences(of: #"\b(\d{1,2}):00\s*([AaPp])[Mm]\b"#, with: "$1 $2M", options: .regularExpression)
        // 2:30pm → 2:30 PM, 3pm → 3 PM
        result = result.replacingOccurrences(of: #"\b(\d{1,2}(?::\d{2})?)\s*([AaPp])[Mm]\b"#, with: "$1 $2M", options: .regularExpression)
        return result.replacingOccurrences(of: " aM", with: " AM").replacingOccurrences(of: " pM", with: " PM")
    }
}
