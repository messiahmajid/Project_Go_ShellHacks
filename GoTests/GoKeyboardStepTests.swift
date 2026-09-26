import CoreGraphics
import Foundation
import Testing
@testable import Go

struct GoKeyboardStepTests {
    @Test func keysAndShortcutsParseAndReadAsSymbols() {
        #expect(GoKeyCombo.parse("return")?.keyCode == 36)
        #expect(GoKeyCombo.parse("cmd+d")?.flags == .maskCommand)
        #expect(GoKeyCombo.parse("cmd+d")?.display == "⌘D")
        #expect(GoKeyCombo.parse("Cmd + Shift + Down")?.display == "⌘⇧↓")
        #expect(GoKeyCombo.parse("tab")?.display == "Tab")
        #expect(GoKeyCombo.parse("hyper+d") == nil)
        #expect(GoKeyCombo.parse("cmd+") == nil)
        #expect(GoKeyCombo.parse("ab") == nil)
    }

    @Test func quittingLockingAndEmptyingTheTrashAreRefusedAndClosingAsks() {
        for keys in ["cmd+q", "ctrl+cmd+q", "cmd+shift+q", "cmd+option+esc", "cmd+shift+delete"] {
            #expect(GoKeyCombo.parse(keys)?.refusal != nil, "\(keys)")
        }
        for keys in ["cmd+w", "cmd+delete"] { #expect(GoKeyCombo.parse(keys)?.needsConfirmation == true, "\(keys)") }
        for keys in ["cmd+d", "cmd+c", "cmd+v", "cmd+z", "return", "tab", "down"] {
            #expect(GoKeyCombo.parse(keys)?.refusal == nil && GoKeyCombo.parse(keys)?.needsConfirmation == false, "\(keys)")
        }
    }

    private var sheet: GoObservation {
        GoObservation(app: "any.sheet", windowToken: "w", windowName: "Sales", complete: true, controls: [])
    }

    @Test func aKeyboardStepTypesIntoFocusAndPressesKeys() {
        var state = GoWalkthroughState()
        var proposal = GoStepProposal(kind: .step, instruction: "Type the formula and press Return.", targetID: "keyboard", expected: nil)
        proposal.typeText = "=B2-C2"; proposal.keys = "return"
        state.accept(proposal, from: sheet)
        #expect(state.phase == .waiting)
        #expect(state.step?.keyboard == true)
        #expect(state.step?.typeText == "=B2-C2")
        #expect(state.message.contains("=B2-C2"))
        #expect(state.step?.targetDescription == "typing \u{201C}=B2-C2\u{201D} then pressing Return")
        #expect(state.step?.kindLabel == "keyboard")
    }

    @Test func dangerousShortcutsAreNeverStepsAndClosingOnesAreConfirmed() {
        var quit = GoWalkthroughState()
        var proposal = GoStepProposal(kind: .step, instruction: "Quit.", targetID: "keyboard", expected: nil)
        proposal.keys = "cmd+q"
        quit.accept(proposal, from: sheet)
        #expect(quit.phase == .needsInput)
        var close = GoWalkthroughState()
        close.accept(GoStepProposal(kind: .step, instruction: "Close the window.", targetID: "keyboard", expected: nil, keys: "cmd+w"), from: sheet)
        close.applyRisk(GoRisk(level: .none, reason: nil), warnOwner: false)
        #expect(close.step?.risk?.level == .confirm)
        var unknown = GoWalkthroughState()
        unknown.accept(GoStepProposal(kind: .step, instruction: "Press it.", targetID: "keyboard", expected: nil, keys: "hyper+x"), from: sheet)
        #expect(unknown.phase == .needsInput)
    }

    @Test func formulasAreTypedOutsideTerminalsAndCommandsAreScreenedInThem() {
        #expect(GoKeystrokes.keyboardRefusal(for: "=IF(B2>C2,\"Yes\",\"No\")", app: "any.sheet") == nil)
        #expect(GoKeystrokes.keyboardRefusal(for: "Please send the report", app: "any.editor") == nil)
        #expect(GoKeystrokes.keyboardRefusal(for: "rm -rf ~/Documents", app: "com.apple.Terminal") != nil)
    }

    @Test func keyboardStepsAreSavedAndReplayedInRoutines() {
        let step = GoWalkthroughStep(instruction: "Fill down.", app: "any.sheet", windowToken: "w", control: nil, menu: nil,
                                     expected: nil, keys: "cmd+d", keyboard: true)
        let saved = GoRoutineStep(step)
        #expect(saved.targetKey == "keyboard:cmd+d:")
        let proposal = GoRoutineReplay.proposal(for: saved, in: sheet)
        #expect(proposal?.targetID == "keyboard")
        #expect(proposal?.keys == "cmd+d")
    }
}
