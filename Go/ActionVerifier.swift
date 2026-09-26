//
//  ActionVerifier.swift
//  Go
//
//  A call returning `.success` only means the message was delivered. An action
//  counts as done when a fresh read of the window shows it changed.
//

import ApplicationServices
import Foundation

nonisolated enum VerificationOutcome: Equatable {
    case confirmed(afterMilliseconds: Int)
    /// The focused window we acted in closed.
    case windowGone(afterMilliseconds: Int)
    case notObserved(afterMilliseconds: Int)
    case couldNotReadWindow
}

nonisolated enum ActionVerifier {

    static func radioPressConfirmed(
        intent: ElementActionIntent,
        previous: AccessibilityElementNode,
        laterRoot: AccessibilityElementNode
    ) -> Bool {
        guard intent.action == .press, previous.role == kAXRadioButtonRole,
              previous.radioSelection == false,
              case .resolved(let later) = ElementActionIntentResolver.resolve(intent, inTreeRootedAt: laterRoot),
              later.role == kAXRadioButtonRole, later.radioSelection == true else { return false }
        if let beforeElement = previous.accessibilityElement {
            guard let afterElement = later.accessibilityElement,
                  CFEqual(beforeElement, afterElement) else { return false }
        }
        return true
    }

    /// A missing window must be seen this many polls in a row (window switches
    /// can briefly leave none focused).
    static let consecutiveMissingWindowPollsRequired = 2

    /// Re-walks the focused window until `expectation` holds or time runs out.
    /// The window we acted in closing also counts as a reaction.
    /// `hadFocusedWindowBefore` must be false when nothing was focused before.
    static func verify(
        hadFocusedWindowBefore: Bool = true,
        expectation: (AccessibilityWindowSnapshot) -> Bool,
        timeoutInSeconds: Double = 3.0,
        pollIntervalInSeconds: Double = 0.15
    ) -> VerificationOutcome {
        verifyCountingWalks(
            hadFocusedWindowBefore: hadFocusedWindowBefore, expectation: expectation,
            timeoutInSeconds: timeoutInSeconds, pollIntervalInSeconds: pollIntervalInSeconds
        ).outcome
    }

    /// `verify`, plus the number of walks and the walk that confirmed the change
    /// (so a caller can describe it without walking again).
    static func verifyCountingWalks(
        hadFocusedWindowBefore: Bool = true,
        expectation: (AccessibilityWindowSnapshot) -> Bool,
        timeoutInSeconds: Double = 3.0,
        pollIntervalInSeconds: Double = 0.15
    ) -> (outcome: VerificationOutcome, walks: Int, confirmingSnapshot: AccessibilityWindowSnapshot?) {
        poll(
            walk: { try AccessibilityTreeWalker.snapshotFocusedWindow() },
            hadFocusedWindowBefore: hadFocusedWindowBefore, expectation: expectation,
            timeoutInSeconds: timeoutInSeconds, pollIntervalInSeconds: pollIntervalInSeconds
        )
    }

    /// Reuse the confirming walk only if it was the first one; a later walk may
    /// have caught the app mid-change.
    static func snapshotToDescribe<Snapshot>(
        confirming: Snapshot?, walks: Int, walkAgain: () -> Snapshot?
    ) -> Snapshot? {
        walks == 1 ? confirming : walkAgain()
    }

    /// `poll` for `menu`: check the window count before each walk, confirming a
    /// moved count without walking.
    static func pollCountingWindowsFirst<Target, Snapshot>(
        locate: () throws -> Target,
        windowCountMoved: () -> Bool,
        walk: (Target) throws -> Snapshot,
        hadFocusedWindowBefore: Bool,
        expectation: (Snapshot) -> Bool,
        timeoutInSeconds: Double = 3.0,
        pollIntervalInSeconds: Double = 0.15
    ) -> (outcome: VerificationOutcome, walks: Int) {
        let (outcome, polls, confirming) = poll(
            walk: { () throws -> Snapshot? in
                let target = try locate()
                if windowCountMoved() { return nil }   // nil: confirmed by the count, not walked
                return try walk(target)
            },
            hadFocusedWindowBefore: hadFocusedWindowBefore,
            expectation: { $0.map(expectation) ?? true },
            timeoutInSeconds: timeoutInSeconds, pollIntervalInSeconds: pollIntervalInSeconds
        )
        if case .some(.none) = confirming { return (outcome, polls - 1) }
        return (outcome, polls)
    }

    /// The loop, generic so tests can drive it without AX.
    static func poll<Snapshot>(
        walk: () throws -> Snapshot,
        hadFocusedWindowBefore: Bool,
        expectation: (Snapshot) -> Bool,
        timeoutInSeconds: Double,
        pollIntervalInSeconds: Double
    ) -> (outcome: VerificationOutcome, walks: Int, confirmingSnapshot: Snapshot?) {
        let startedAt = Date()
        var sawAnyWindow = false
        var pollErrors: [Error?] = []

        func elapsedMilliseconds() -> Int { Int(Date().timeIntervalSince(startedAt) * 1000) }

        while Date().timeIntervalSince(startedAt) < timeoutInSeconds {
            do {
                let snapshot = try walk()
                sawAnyWindow = true
                pollErrors.append(nil)
                if expectation(snapshot) {
                    return (.confirmed(afterMilliseconds: elapsedMilliseconds()), pollErrors.count, snapshot)
                }
            } catch {
                pollErrors.append(error)
                if let gone = outcome(
                    afterPolls: pollErrors, elapsedMilliseconds: elapsedMilliseconds(),
                    hadFocusedWindowBefore: hadFocusedWindowBefore
                ) {
                    return (gone, pollErrors.count, nil)
                }
            }
            Thread.sleep(forTimeInterval: pollIntervalInSeconds)
        }

        // One entry per walk, so the count is the walk count.
        return (sawAnyWindow ? .notObserved(afterMilliseconds: elapsedMilliseconds()) : .couldNotReadWindow,
                pollErrors.count, nil)
    }

    /// The window-closed decision, pure. Only `.noFocusedWindow` counts; a failure
    /// to look is never evidence of change.
    static func outcome(
        afterPolls: [Error?],
        elapsedMilliseconds: Int,
        hadFocusedWindowBefore: Bool = true
    ) -> VerificationOutcome? {
        guard hadFocusedWindowBefore else { return nil }
        let recent = afterPolls.suffix(consecutiveMissingWindowPollsRequired)
        let allGaps = recent.count == consecutiveMissingWindowPollsRequired
            && recent.allSatisfy { ($0 as? AccessibilitySnapshotError) == .noFocusedWindow }
        return allGaps ? .windowGone(afterMilliseconds: elapsedMilliseconds) : nil
    }
}
