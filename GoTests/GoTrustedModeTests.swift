import Foundation
import Testing
@testable import Go

struct GoTrustedModeTests {
    @Test func trustedModeApprovesOnlyNonDestructiveQuestions() {
        #expect(GoTrustedMode.approves(destructive: false, isOn: true))
        #expect(!GoTrustedMode.approves(destructive: true, isOn: true))
        #expect(!GoTrustedMode.approves(destructive: false, isOn: false))
    }

    @Test func deletingStillAsksAndIrreversibleOrPasswordActionsStayRefused() {
        // Destructive words are what keep a question a question in trusted mode.
        for word in ["delete", "remove", "trash", "move to bin"] {
            #expect(ActionSafetyKernel.destructiveTitleKeywords.contains(word))
        }
        for word in ["erase", "empty trash", "buy", "pay", "purchase"] {
            #expect(ActionSafetyKernel.irreversibleTitleKeywords.contains(word))
        }
        #expect(ActionSafetyKernel.secureFieldSubrole == "AXSecureTextField")
    }

    @Test func timesAreReadNaturally() {
        #expect(GoSpeechText.spoken("Set it for 2:00 PM.") == "Set it for 2 PM.")
        #expect(GoSpeechText.spoken("at 2:00pm tomorrow") == "at 2 PM tomorrow")
        #expect(GoSpeechText.spoken("from 9:30am to 11:15 p.m.") == "from 9:30 AM to 11:15 PM")
        #expect(GoSpeechText.spoken("Meet at 3pm") == "Meet at 3 PM")
        #expect(GoSpeechText.spoken("Click Save.") == "Click Save.")
        #expect(GoSpeechText.spoken("Version 2:00 build") == "Version 2:00 build")
    }
}

/// What Go says is speakable; the bubble keeps the exact text.
struct GoSpeakableTextTests {
    @Test func shortcutSymbolsAreSaidAsWords() {
        #expect(GoSpeechText.spoken("Make it bold. (⌘B)") == "Make it bold. (command B)")
        #expect(GoSpeechText.spoken("Save a copy (⌘⇧S).") == "Save a copy (command shift S).")
    }

    @Test func formulasCodeAndAddressesAreReferredToNotReadOut() {
        #expect(GoSpeechText.spoken("Type \u{201C}=IF(C2>=D2,\"Yes\",\"No\")\u{201D} in E2.") == "Type the formula shown in E2.")
        #expect(GoSpeechText.spoken("Type \u{201C}=C2-B2\u{201D}, then press Return.") == "Type the formula shown, then press Return.")
        #expect(GoSpeechText.spoken("Open https://example.com/a?b=1 in Safari.") == "Open the text shown in Safari.")
        #expect(GoSpeechText.spoken("Type \"~/Library/Logs/Go\" in the box.") == "Type the text shown in the box.")
    }

    @Test func ordinaryTextIsLeftAlone() {
        for text in ["Type \u{201C}Road trip\u{201D} in the name field.", "Click Insert, then Table.",
                     "Select B2:B6.", "Send it to a@b.com.", "Name it \u{201C}Q3 Report.docx\u{201D}."] {
            #expect(GoSpeechText.spoken(text) == text, "\(text)")
        }
        #expect(GoSpeechText.spoken("One sec…") == "One sec.")
    }
}
