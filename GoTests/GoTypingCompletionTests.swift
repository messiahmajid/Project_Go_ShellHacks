import CoreGraphics
import Foundation
import Testing
@testable import Go

/// Typing steps finish on what was typed, never on a pause alone.
struct GoTypingCompletionTests {
    private func verdict(_ contents: String?, matchedBefore: Bool = false, committed: Bool = false,
                         needsCommit: Bool = false, quiet: TimeInterval = 1.5) -> GoGuidePresenter.TypingVerdict {
        GoGuidePresenter.typingVerdict(contents: contents, text: "=C2-B2", matchedBefore: matchedBefore, committed: committed,
                                       needsCommit: needsCommit, quietSeconds: quiet)
    }

    @Test func aPauseHalfwayThroughIsNotDone() {
        // The old rule finished here: something typed, then a pause.
        #expect(verdict("=C2-", quiet: 3) == .notYet(matched: false))
        #expect(verdict("=C2-", committed: true) == .notYet(matched: false))   // Return on a typo
    }

    @Test func aReadableFieldFinishesOnceItHoldsTheText() {
        #expect(verdict("=C2-B2") == .notYet(matched: true))                   // seen once
        #expect(verdict("=C2-B2", matchedBefore: true) == .finished(confirmed: true))
        // A step that ends with Return waits for it, then finishes.
        #expect(verdict("=C2-B2", matchedBefore: true, needsCommit: true) == .notYet(matched: true))
        #expect(verdict("=C2-B2", committed: true, needsCommit: true) == .finished(confirmed: true))
    }

    @Test func anUnreadableFieldFinishesOnACommitOrALongPauseWithoutPraise() {
        #expect(verdict(nil, quiet: 2) == .notYet(matched: false))
        #expect(verdict(nil, committed: true) == .finished(confirmed: false))
        #expect(verdict(nil, quiet: 5) == .notYet(matched: false))              // a pause to look something up
        #expect(verdict(nil, quiet: 11) == .finished(confirmed: false))
        #expect(verdict(nil, needsCommit: true, quiet: 9) == .notYet(matched: false))
        // Return closed the editor right after a matching read: that was seen.
        #expect(verdict(nil, matchedBefore: true, committed: true) == .finished(confirmed: true))
    }

    @Test func typingContinuesWhatIsAlreadyInTheField() {
        #expect(GoTextFields.remainder(of: "=C2-B2", after: "=C2-") == "B2")
        #expect(GoTextFields.remainder(of: "=C2-B2", after: "=C2-B2") == "")
        #expect(GoTextFields.remainder(of: "=C2-B2", after: "") == "=C2-B2")
        #expect(GoTextFields.remainder(of: "=C2-B2", after: nil) == "=C2-B2")
        #expect(GoTextFields.remainder(of: "=C2-B2", after: "Total") == "=C2-B2")
    }

    @Test func theSameTextAskedAgainIsRecognised() {
        func step(_ text: String?, app: String = "any.app") -> GoWalkthroughStep {
            GoWalkthroughStep(instruction: "Type it.", app: app, windowToken: "w", control: nil, menu: nil, expected: nil, typeText: text)
        }
        #expect(GoWalkthroughCoordinator.repeatsTyping(done: step("=C2-B2"), next: step("= c2 - b2")))
        #expect(!GoWalkthroughCoordinator.repeatsTyping(done: step("=C2-B2"), next: step("=D2-C2")))
        #expect(!GoWalkthroughCoordinator.repeatsTyping(done: step("=C2-B2"), next: step("=C2-B2", app: "other.app")))
        #expect(!GoWalkthroughCoordinator.repeatsTyping(done: step(nil), next: step("=C2-B2")))
    }
}

/// Praise and "not quite yet" come from checking the finished step, never from
/// the owner's activity alone.
struct GoStepFeedbackTests {
    private func feedback(_ verdict: String?, reacted: Bool = false, typed: Bool = false, repeats: Bool = false,
                          reveal: Bool = false) -> GoWalkthroughCoordinator.StepFeedback? {
        GoWalkthroughCoordinator.feedback(verdict: verdict, check: (reacted, typed), repeatsTyping: repeats, reveal: reveal)
    }

    @Test func praiseNeedsTheStepToBeSeenWorking() {
        #expect(feedback("worked") == .praise)
        #expect(feedback("unclear") == nil)                    // can't tell: say nothing
        #expect(feedback(nil) == nil)
        #expect(feedback("unclear", reacted: true) == .praise) // Go saw the screen change
        #expect(feedback("unclear", typed: true) == .praise)   // Go read the typed text
        #expect(feedback("worked", reveal: true) == nil)       // scrolling isn't progress
        #expect(feedback("unclear", reacted: true, reveal: true) == nil)
    }

    @Test func aStepThatDidNotTakeIsCalledOut() {
        #expect(feedback("notYet", reacted: true, typed: true) == .notYet)
        #expect(feedback("worked", repeats: true) == .notYet)
    }
}

/// Questions about the step being shown are answered from the step.
struct GoStepQuestionTests {
    @Test func questionsAboutThisStepAreRecognised() {
        for heard in ["Where should I type it?", "Where?", "Which one?", "What do I type?", "Where do I click?",
                      "Say that again", "Sorry, I didn't catch that", "I don't see it", "Where is it?"] {
            #expect(GoGuidanceIntent.asksAboutCurrentStep(heard), "\(heard)")
        }
    }

    @Test func newQuestionsAreNotMistakenForThem() {
        for heard in ["Where is the Bold button?", "Where do I go to insert a chart?", "Make the title bold",
                      "How do I add a chart?", "What's the weather like?"] {
            #expect(!GoGuidanceIntent.asksAboutCurrentStep(heard), "\(heard)")
        }
    }
}

