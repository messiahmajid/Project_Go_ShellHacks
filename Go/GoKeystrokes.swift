import AppKit
import Carbon.HIToolbox

/// Real keystrokes for fields that accept keys but not an Accessibility value
/// write (Terminal, some editors and web canvases). Used only after the kernel
/// refused a value write as not settable, and only past `refusal(for:)`.
nonisolated enum GoKeystrokes {
    /// Command fragments that delete, force, escalate or execute downloaded code.
    /// A match hands the step to the owner; it is not a complete shell parser.
    private static let riskyCommandPatterns = [
        #"(^|[\s;&|(])(sudo|su|doas)\b"#, #"(^|[\s;&|(])(rm|rmdir|shred|srm|unlink)\b"#, #"(^|[\s;&|(])(dd|mkfs\S*|fdisk|diskutil)\b"#,
        #"(^|[\s;&|(])(kill|killall|pkill)\b"#, #"(^|[\s;&|(])(chmod|chown|chflags)\b"#, #"(^|[\s;&|(])(shutdown|reboot|halt)\b"#,
        #"(^|[\s;&|(])(launchctl|csrutil|spctl|tccutil)\b"#, #"\bgit\s+(reset\s+--hard|clean\b|push\b.*--force|push\b.*\s-f\b)"#,
        #"\bdefaults\s+delete\b"#, #"\|\s*(sh|bash|zsh)\b"#, #"(curl|wget)\b.*\|"#, #"(^|[^>])>\s*[^>&\s]"#, #":\(\)\s*\{"#, #"\bmv\b.*\s/(\s|$)"#
    ]

    /// Why Go must not type this itself, or nil when it may.
    static func refusal(for text: String) -> String? {
        if IsSecureEventInputEnabled() { return "a password prompt or secure input is active" }
        let lowered = text.lowercased()
        if riskyCommandPatterns.contains(where: { lowered.range(of: $0, options: .regularExpression) != nil }) {
            return "that command could delete or change things, so please run it yourself"
        }
        if ActionSafetyKernel.irreversibleTitleKeywords.contains(where: { lowered.contains($0) })
            || ActionSafetyKernel.destructiveTitleKeywords.contains(where: { lowered.contains($0) }) {
            return "that looks like it deletes or sends something, so please do it yourself"
        }
        return nil
    }

    /// Types `text` into the app's focused element with key events, if the app
    /// is frontmost and its focused element is not a password field.
    static func type(_ text: String, app bundleIdentifier: String) -> Bool {
        guard GoActiveApp.isActive(bundleIdentifier),
              let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first,
              !GoTextFields.secureFieldFocused(app: bundleIdentifier), !IsSecureEventInputEnabled() else { return false }
        for scalar in text.unicodeScalars {
            var units = Array(String(scalar).utf16)
            guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) else { return false }
            down.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
            up.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
            down.postToPid(running.processIdentifier)
            up.postToPid(running.processIdentifier)
            usleep(4_000)
        }
        return true
    }
}

/// A key or shortcut the planner asked for, like "return", "tab", "down",
/// "cmd+d" or "cmd+shift+down".
nonisolated struct GoKeyCombo: Equatable, Sendable {
    let keyCode: CGKeyCode
    let flags: CGEventFlags
    /// How it reads on screen, e.g. "⌘D".
    let display: String

    private static let modifiers: [String: (CGEventFlags, String)] = [
        "cmd": (.maskCommand, "⌘"), "command": (.maskCommand, "⌘"), "shift": (.maskShift, "⇧"),
        "option": (.maskAlternate, "⌥"), "opt": (.maskAlternate, "⌥"), "alt": (.maskAlternate, "⌥"),
        "ctrl": (.maskControl, "⌃"), "control": (.maskControl, "⌃")
    ]
    private static let named: [String: (CGKeyCode, String)] = [
        "return": (36, "Return"), "enter": (36, "Return"), "tab": (48, "Tab"), "space": (49, "Space"),
        "escape": (53, "Esc"), "esc": (53, "Esc"), "delete": (51, "Delete"), "backspace": (51, "Delete"),
        "forwarddelete": (117, "Forward Delete"), "up": (126, "↑"), "down": (125, "↓"), "left": (123, "←"),
        "right": (124, "→"), "home": (115, "Home"), "end": (119, "End"), "pageup": (116, "Page Up"),
        "pagedown": (121, "Page Down"), "f1": (122, "F1"), "f2": (120, "F2"), "f3": (99, "F3"), "f4": (118, "F4"),
        "f5": (96, "F5"), "f6": (97, "F6"), "f7": (98, "F7"), "f8": (100, "F8"), "f9": (101, "F9"),
        "f10": (109, "F10"), "f11": (103, "F11"), "f12": (111, "F12")
    ]
    /// ANSI key codes for single characters.
    private static let characters: [Character: CGKeyCode] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12,
        "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23,
        "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34,
        "p": 35, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46,
        ".": 47, "`": 50
    ]

    /// Nil for anything malformed: unknown names, several keys, or no key.
    static func parse(_ text: String) -> GoKeyCombo? {
        let parts = text.lowercased().replacingOccurrences(of: " ", with: "").split(separator: "+").map(String.init)
        guard let keyName = parts.last, !keyName.isEmpty else { return nil }
        var flags = CGEventFlags()
        var display = ""
        for part in parts.dropLast() {
            guard let (flag, symbol) = modifiers[part] else { return nil }
            if !flags.contains(flag) { flags.insert(flag); display += symbol }
        }
        if let (code, name) = named[keyName] {
            return GoKeyCombo(keyCode: code, flags: flags, display: display + (display.isEmpty ? name : name.count > 1 ? " " + name : name))
        }
        guard keyName.count == 1, let character = keyName.first, let code = characters[character] else { return nil }
        return GoKeyCombo(keyCode: code, flags: flags, display: display + keyName.uppercased())
    }

    private var isCommand: Bool { flags.contains(.maskCommand) }

    /// Shortcuts Go never presses: quitting, logging out, locking, force quit,
    /// emptying the Trash.
    var refusal: String? {
        let quit = isCommand && keyCode == 12                                   // ⌘Q, ⌃⌘Q, ⇧⌘Q, ⌥⌘Q
        let forceQuit = isCommand && flags.contains(.maskAlternate) && keyCode == 53
        let emptyTrash = isCommand && flags.contains(.maskShift) && keyCode == 51
        let powerOrLock = flags.contains(.maskControl) && isCommand && (keyCode == 12 || keyCode == 116 || keyCode == 121)
        guard quit || forceQuit || emptyTrash || powerOrLock else { return nil }
        return "that shortcut quits, locks or empties something, so please press it yourself"
    }

    /// Shortcuts that can close or delete: Go asks first.
    var needsConfirmation: Bool {
        guard refusal == nil else { return false }
        return isCommand && (keyCode == 13 || keyCode == 51 || keyCode == 117)  // ⌘W, ⌘Delete, ⌘Forward Delete
    }
}

nonisolated extension GoKeystrokes {
    /// Terminal apps, where typed text runs as a command and gets the command screening.
    static func isTerminal(_ bundleIdentifier: String) -> Bool {
        let known: Set<String> = ["com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "co.zeit.hyper",
                                  "net.kovidgoyal.kitty", "org.alacritty", "io.alacritty", "com.github.wez.wezterm",
                                  "com.mitchellh.ghostty"]
        if known.contains(bundleIdentifier) { return true }
        let name = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first?.localizedName?.lowercased() ?? ""
        return name.contains("terminal")
    }

    /// Why Go must not type `text` into `app` itself, or nil. Command screening
    /// applies in terminals; everywhere, secure input stops typing.
    static func keyboardRefusal(for text: String, app: String) -> String? {
        if IsSecureEventInputEnabled() { return "a password prompt or secure input is active" }
        return isTerminal(app) ? refusal(for: text) : nil
    }

    /// Presses a key combination in the app's front window, if the app is in
    /// front and no password field or secure input has focus.
    static func press(_ combo: GoKeyCombo, app bundleIdentifier: String) -> Bool {
        guard GoActiveApp.isActive(bundleIdentifier),
              let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first,
              !GoTextFields.secureFieldFocused(app: bundleIdentifier), !IsSecureEventInputEnabled(),
              let down = CGEvent(keyboardEventSource: nil, virtualKey: combo.keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: combo.keyCode, keyDown: false) else { return false }
        down.flags = combo.flags
        up.flags = combo.flags
        down.postToPid(running.processIdentifier)
        usleep(8_000)
        up.postToPid(running.processIdentifier)
        return true
    }
}
