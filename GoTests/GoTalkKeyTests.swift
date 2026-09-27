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

/// A shortcut the planner only named in words is still pressed; one it didn't
/// name clearly never is.
struct GoMentionedShortcutTests {
    @Test func aShortcutNamedInWordsIsRead() {
        #expect(GoKeyCombo.mentioned(in: "Press Command-T to open a new tab.") == "command+t")
        #expect(GoKeyCombo.mentioned(in: "Use Cmd+Shift+N for a new folder.") == "cmd+shift+n")
        #expect(GoKeyCombo.mentioned(in: "Press \u{2318}W to close it.") == "cmd+w")
        #expect(GoKeyCombo.mentioned(in: "Then press Return.") == "return")
    }

    @Test func noShortcutOrTwoOfThemIsNotGuessed() {
        #expect(GoKeyCombo.mentioned(in: "Click the New Tab button.") == nil)
        #expect(GoKeyCombo.mentioned(in: "Press Command-C, then Command-V.") == nil)
    }

    @Test func aKeyboardStepWithoutKeysUsesTheOneItNames() {
        let observation = GoObservation(app: "any.browser", windowToken: "w", windowName: "Inbox", complete: true, controls: [])
        var state = GoWalkthroughState()
        state.accept(GoStepProposal(kind: .step, instruction: "Press Command-T to open a new tab.", targetID: "keyboard", expected: nil),
                     from: observation)
        #expect(state.phase == .waiting)
        #expect(state.step?.keys == "command+t")
    }
}
