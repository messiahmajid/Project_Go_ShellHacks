import AppKit
import Foundation

/// The push-to-talk key combinations and how their key events are recognised.
enum PushToTalkShortcut {
    enum ShortcutOption: String, CaseIterable {
        /// The right Option key alone: one finger, and rarely used on its own.
        case rightOption
        case shiftFunction
        case controlOption
        case shiftControl
        case controlOptionSpace
        case shiftControlSpace

        /// The choices offered in the panel.
        static let offered: [ShortcutOption] = [.rightOption, .controlOption]

        var displayName: String {
            switch self {
            case .rightOption: return "Right Option"
            case .controlOption: return "Control + Option"
            case .shiftFunction: return "Shift + Fn"
            case .shiftControl: return "Shift + Control"
            case .controlOptionSpace: return "Control + Option + Space"
            case .shiftControlSpace: return "Shift + Control + Space"
            }
        }

        /// How Go says it: "hold the right Option key to talk".
        var holdPhrase: String {
            self == .rightOption ? "the right Option key" : displayName
        }

        /// The keys drawn in the panel, as symbol and name.
        var keyCaps: [(symbol: String, name: String)] {
            switch self {
            case .rightOption: return [("\u{2325}", "right option")]
            case .controlOption: return [("\u{2303}", "control"), ("\u{2325}", "option")]
            case .shiftFunction: return [("\u{21E7}", "shift"), ("fn", "")]
            case .shiftControl: return [("\u{21E7}", "shift"), ("\u{2303}", "control")]
            case .controlOptionSpace: return [("\u{2303}", "control"), ("\u{2325}", "option"), ("\u{2423}", "space")]
            case .shiftControlSpace: return [("\u{21E7}", "shift"), ("\u{2303}", "control"), ("\u{2423}", "space")]
            }
        }

        /// A single modifier can also start a typed character (Option + e for é):
        /// it counts only once held alone for a moment.
        var holdDelaySeconds: Double { self == .rightOption ? 0.25 : 0 }

        fileprivate var modifierOnlyFlags: NSEvent.ModifierFlags? {
            switch self {
            case .rightOption:
                return nil
            case .shiftFunction:
                return [.shift, .function]
            case .controlOption:
                return [.control, .option]
            case .shiftControl:
                return [.shift, .control]
            case .controlOptionSpace, .shiftControlSpace:
                return nil
            }
        }

        fileprivate var spaceShortcutModifierFlags: NSEvent.ModifierFlags? {
            switch self {
            case .rightOption:
                return nil
            case .shiftFunction:
                return nil
            case .controlOption:
                return nil
            case .shiftControl:
                return nil
            case .controlOptionSpace:
                return [.control, .option]
            case .shiftControlSpace:
                return [.shift, .control]
            }
        }
    }

    enum ShortcutTransition {
        case none
        case pressed
        case released
    }

    private enum ShortcutEventType {
        case flagsChanged
        case keyDown
        case keyUp
    }

    static let defaultsKey = "pushToTalkShortcut"
    /// The owner's choice in the panel; the right Option key unless changed.
    static var currentShortcutOption: ShortcutOption {
        UserDefaults.standard.string(forKey: defaultsKey).flatMap(ShortcutOption.init(rawValue:)) ?? .rightOption
    }

    /// The right Option key's own bit in an event's raw modifier flags (the
    /// left one's is 0x20); the device-independent flags can't tell them apart.
    static let rightOptionRawBit: UInt64 = 0x40
    static let leftOptionRawBit: UInt64 = 0x20
    static let pushToTalkKeyCode: UInt16 = 49 // Space

    static func shortcutTransition(
        for event: NSEvent,
        wasShortcutPreviouslyPressed: Bool
    ) -> ShortcutTransition {
        guard let shortcutEventType = shortcutEventType(for: event.type) else { return .none }
        if currentShortcutOption == .rightOption {
            return rightOptionTransition(isFlagsChanged: shortcutEventType == .flagsChanged,
                                         rawFlags: UInt64(event.modifierFlags.rawValue), wasPressed: wasShortcutPreviouslyPressed)
        }

        return shortcutTransition(
            for: shortcutEventType,
            keyCode: event.keyCode,
            modifierFlags: event.modifierFlags.intersection(.deviceIndependentFlagsMask),
            wasShortcutPreviouslyPressed: wasShortcutPreviouslyPressed
        )
    }

    static func shortcutTransition(
        for eventType: CGEventType,
        keyCode: UInt16,
        modifierFlagsRawValue: UInt64,
        wasShortcutPreviouslyPressed: Bool,
        option: ShortcutOption = currentShortcutOption
    ) -> ShortcutTransition {
        guard let shortcutEventType = shortcutEventType(for: eventType) else { return .none }
        if option == .rightOption {
            return rightOptionTransition(isFlagsChanged: shortcutEventType == .flagsChanged,
                                         rawFlags: modifierFlagsRawValue, wasPressed: wasShortcutPreviouslyPressed)
        }

        return shortcutTransition(
            for: shortcutEventType,
            keyCode: keyCode,
            modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(modifierFlagsRawValue))
                .intersection(.deviceIndependentFlagsMask),
            wasShortcutPreviouslyPressed: wasShortcutPreviouslyPressed
        )
    }

    /// Down while the right Option key is held with no other modifier; up when
    /// it's let go or another modifier joins it.
    static func rightOptionTransition(isFlagsChanged: Bool, rawFlags: UInt64, wasPressed: Bool) -> ShortcutTransition {
        guard isFlagsChanged else { return .none }
        let others = NSEvent.ModifierFlags(rawValue: UInt(rawFlags)).intersection([.command, .control, .shift, .function])
        let alone = rawFlags & rightOptionRawBit != 0 && rawFlags & leftOptionRawBit == 0 && others.isEmpty
        if alone && !wasPressed { return .pressed }
        if !alone && wasPressed { return .released }
        return .none
    }

    private static func shortcutEventType(for eventType: NSEvent.EventType) -> ShortcutEventType? {
        switch eventType {
        case .flagsChanged:
            return .flagsChanged
        case .keyDown:
            return .keyDown
        case .keyUp:
            return .keyUp
        default:
            return nil
        }
    }

    private static func shortcutEventType(for eventType: CGEventType) -> ShortcutEventType? {
        switch eventType {
        case .flagsChanged:
            return .flagsChanged
        case .keyDown:
            return .keyDown
        case .keyUp:
            return .keyUp
        default:
            return nil
        }
    }

    private static func shortcutTransition(
        for shortcutEventType: ShortcutEventType,
        keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags,
        wasShortcutPreviouslyPressed: Bool
    ) -> ShortcutTransition {
        if let modifierOnlyFlags = currentShortcutOption.modifierOnlyFlags {
            guard shortcutEventType == .flagsChanged else { return .none }

            let isShortcutCurrentlyPressed = modifierFlags.contains(modifierOnlyFlags)

            if isShortcutCurrentlyPressed && !wasShortcutPreviouslyPressed {
                return .pressed
            }

            if !isShortcutCurrentlyPressed && wasShortcutPreviouslyPressed {
                return .released
            }

            return .none
        }

        guard let pushToTalkModifierFlags = currentShortcutOption.spaceShortcutModifierFlags else {
            return .none
        }

        let matchesModifierFlags = modifierFlags.isSuperset(of: pushToTalkModifierFlags)

        if shortcutEventType == .keyDown
            && keyCode == pushToTalkKeyCode
            && matchesModifierFlags
            && !wasShortcutPreviouslyPressed {
            return .pressed
        }

        if shortcutEventType == .keyUp
            && keyCode == pushToTalkKeyCode
            && wasShortcutPreviouslyPressed {
            return .released
        }

        return .none
    }
}
