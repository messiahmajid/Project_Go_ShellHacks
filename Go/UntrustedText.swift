//
//  UntrustedText.swift
//  Go
//
//  Text written by other apps (accessibility names), wrapped so it must be
//  used deliberately: `.raw` to compare, `.forDisplay` to show or log.
//

import Foundation

/// A string published by another app. Names can contain anything, including
/// instructions or newlines that forge lines, so there is no implicit conversion.
nonisolated struct UntrustedText: Equatable, Hashable, CustomStringConvertible {

    /// Exactly what the app published. Compare with it; never print or prompt with it.
    let raw: String

    init(_ raw: String) {
        self.raw = raw
    }

    /// Longer than this is content, not a control label.
    static let maximumLabelLength = 128

    /// Displayed names are capped at this length.
    static let maximumDisplayLength = 100

    /// Non-empty, short, and free of control characters (which could forge lines).
    var isPlausibleControlLabel: Bool {
        !raw.isEmpty
            && raw.count <= Self.maximumLabelLength
            && !raw.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    /// Quoted, escaped and capped, keeping the true length: the only form that
    /// may reach a file, a log or a model.
    var forDisplay: String {
        guard raw.count > Self.maximumDisplayLength else {
            return "\"\(Self.escaped(raw))\""
        }
        let head = Self.escaped(String(raw.prefix(Self.maximumDisplayLength)))
        return "\"\(head)…\" (\(raw.count) chars)"
    }

    /// Like `forDisplay` but never truncated, for confirmation questions that must
    /// show everything; those callers refuse over-long text instead.
    var forDisplayInFull: String {
        "\"\(Self.escaped(raw))\""
    }

    /// Interpolation gives the escaped form.
    var description: String { forDisplay }

    private static func escaped(_ text: String) -> String {
        var result = ""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\\": result += "\\\\"
            case "\"": result += "\\\""
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            default:
                // Also escape line and paragraph separators (they break lines in SwiftUI)
                // and unusual spaces (they look identical to a normal space).
                let category = scalar.properties.generalCategory
                if CharacterSet.controlCharacters.contains(scalar)
                    || category == .lineSeparator || category == .paragraphSeparator
                    || (category == .spaceSeparator && scalar != " ") {
                    result += String(format: "\\u{%02X}", scalar.value)
                } else {
                    result.unicodeScalars.append(scalar)
                }
            }
        }
        return result
    }
}
