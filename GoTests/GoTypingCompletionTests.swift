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
        #expect(verdict(nil, quiet: 5) == .finished(confirmed: false))
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
