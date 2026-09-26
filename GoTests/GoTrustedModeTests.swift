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
