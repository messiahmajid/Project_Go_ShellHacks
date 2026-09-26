import Foundation
import Testing
@testable import Go

struct GoVoiceActionPolicyTests {
    @Test func guidanceAndMissingSpeechDoNotAuthorizeActions() {
        for words in [nil, "", "How do I create a project?", "How do I?", "Walk me through creating a project",
                      "Can you show me how to open it?", "Where is Create New?",
                      "Open the app? No, do not do it", "Please don't click", "Go, stop", "What next?",
                      "Create it without clicking anything", "Can I open the window?",
                      "Go ahead and show me how to rename it"] as [String?] {
            #expect(!GoVoiceActionPolicy.allowsActions(heard: words))
        }
    }

    @Test func directCommandsStillUseTheExistingActionPath() {
        for words in ["Open Calendar", "Go, please open Calendar", "Could you create a new window?",
                      "Please select list view", "Can you press New for me?",
                      // Everyday lead-ins and verbs.
                      "Okay, create a new file in the terminal", "I want you to make a new folder",
                      "Now type hello in the search bar", "Go ahead and rename it to Notes", "Write a note that says hi",
                      "Hey, add a new tab", "Can you please save this document",
                      // Statements of what the owner wants done.
                      "Help me create it", "I want to open Calendar"] {
            #expect(GoVoiceActionPolicy.allowsActions(heard: words))
        }
    }

    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []
        var count: Int { lock.lock(); defer { lock.unlock() }; return lines.count }
        func answer(_ line: String) -> String {
            lock.lock(); defer { lock.unlock() }; lines.append(line)
            return #"{"ok":false,"error":"kernelRefused"}"#
        }
    }

    @Test func readOnlyBoundaryBlocksActionsIncludingImplicitFocusAndUnknownVerbs() throws {
        let recorder = Recorder()
        let answer = GoVoiceActionPolicy.guardedAnswer(allowActions: false, answer: { recorder.answer($0) })
        for verb in ["launch", "focus", "press", "menu", "select", "type", "open", "futureAction"] {
            let line = String(decoding: try JSONSerialization.data(withJSONObject: ["verb": verb]), as: UTF8.self)
            #expect(RealtimeOpenAppTool.harnessResponseObject(answer(line))["error"] as? String == "guidanceOnly")
        }
        #expect(answer("invalid") == GoVoiceActionPolicy.refusal)
        #expect(recorder.count == 0)
        for verb in ["snapshot", "menus", "status"] { _ = answer("{\"verb\":\"\(verb)\"}") }
        #expect(recorder.count == 3)
    }

    @Test func explicitPermissionDoesNotOverrideTheKernelResult() {
        let recorder = Recorder()
        let answer = GoVoiceActionPolicy.guardedAnswer(allowActions: true, answer: { recorder.answer($0) })
        let result = RealtimeOpenAppTool.harnessResponseObject(answer(#"{"verb":"press"}"#))
        #expect(recorder.count == 1)
        #expect(result["ok"] as? Bool == false)
        #expect(result["error"] as? String == "kernelRefused")
    }
}
