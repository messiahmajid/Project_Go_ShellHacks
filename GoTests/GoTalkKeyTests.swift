import AppKit
import Testing
@testable import Go

/// The talk key: the right Option key alone, or Control + Option if chosen.
struct GoTalkKeyTests {
    private let right: UInt64 = PushToTalkShortcut.rightOptionRawBit | UInt64(NSEvent.ModifierFlags.option.rawValue)
    private let left: UInt64 = PushToTalkShortcut.leftOptionRawBit | UInt64(NSEvent.ModifierFlags.option.rawValue)

    @Test func theRightOptionKeyAloneStartsAndStopsTalking() {
        #expect(PushToTalkShortcut.rightOptionTransition(isFlagsChanged: true, rawFlags: right, wasPressed: false) == .pressed)
        #expect(PushToTalkShortcut.rightOptionTransition(isFlagsChanged: true, rawFlags: 0, wasPressed: true) == .released)
        #expect(PushToTalkShortcut.rightOptionTransition(isFlagsChanged: true, rawFlags: right, wasPressed: true) == .none)
    }

    @Test func otherKeysAndTheLeftOptionKeyDontCount() {
        #expect(PushToTalkShortcut.rightOptionTransition(isFlagsChanged: true, rawFlags: left, wasPressed: false) == .none)
        let withCommand = right | UInt64(NSEvent.ModifierFlags.command.rawValue)
        #expect(PushToTalkShortcut.rightOptionTransition(isFlagsChanged: true, rawFlags: withCommand, wasPressed: false) == .none)
        // Another modifier joining ends it (a shortcut, not talking).
        #expect(PushToTalkShortcut.rightOptionTransition(isFlagsChanged: true, rawFlags: withCommand, wasPressed: true) == .released)
        // Keys themselves never start it; the monitor cancels a waiting start on a key press.
        #expect(PushToTalkShortcut.rightOptionTransition(isFlagsChanged: false, rawFlags: right, wasPressed: false) == .none)
        #expect(PushToTalkShortcut.ShortcutOption.rightOption.holdDelaySeconds > 0)
        #expect(PushToTalkShortcut.ShortcutOption.controlOption.holdDelaySeconds == 0)
    }

    @Test func theChoiceIsDescribedAsItIsHeld() {
        #expect(PushToTalkShortcut.ShortcutOption.offered == [.rightOption, .controlOption])
        #expect(PushToTalkShortcut.ShortcutOption.rightOption.holdPhrase == "the right Option key")
        #expect(PushToTalkShortcut.ShortcutOption.controlOption.holdPhrase == "Control + Option")
        #expect(PushToTalkShortcut.ShortcutOption.controlOption.keyCaps.map(\.name) == ["control", "option"])
    }
}
