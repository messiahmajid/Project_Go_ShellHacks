import Foundation
import Testing
@testable import Go

@MainActor
struct GoGoalStoreTests {
    private func withStore(_ body: (GoGoalStore, URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("goal.json")
        try body(GoGoalStore(url: url), url)
    }

    private func set(_ store: GoGoalStore) -> [String: Any] {
        store.apply(GoGoalRequest(operation: .set, expectedRevision: store.state.revision,
                                 sourceQuote: "Help me export this vertically with captions", task: "export this video"),
                    heard: "Help me export this vertically with captions.")
    }

    @Test func updateKeepsTheOriginalWordsAndStoresTheRefinementAcrossReload() throws {
        try withStore { store, url in
            #expect(set(store)["ok"] as? Bool == true)
            let id = store.activeGoal?.id
            let result = store.apply(GoGoalRequest(operation: .update, expectedRevision: 1, sourceQuote: "Actually make it landscape"),
                                     heard: "Actually, make it landscape.")
            #expect(result["ok"] as? Bool == true)
            #expect(result["uiChanged"] as? Bool == false)
            let reloaded = GoGoalStore(url: url)
            #expect(reloaded.state == store.state)
            #expect(reloaded.activeGoal?.id == id)
            #expect(reloaded.activeGoal?.rawGoal == "Help me export this vertically with captions.")
            #expect(reloaded.activeGoal?.lastInstruction == "Actually, make it landscape.")
            #expect(reloaded.activeGoal?.task == "export this video")
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        }
    }

    @Test func completeStopsActiveGoalAndClearPersistsItsRevision() throws {
        try withStore { store, url in
            _ = set(store)
            #expect(store.apply(GoGoalRequest(operation: .complete, expectedRevision: 1, sourceQuote: "My goal is complete"),
                                heard: "My goal is complete")["ok"] as? Bool == true)
            #expect(store.activeGoal == nil)
            #expect(GoGoalStore(url: url).state.goal?.status == .completed)
            #expect(store.apply(GoGoalRequest(operation: .update, expectedRevision: 2, sourceQuote: "Change it"),
                                heard: "Change it")["error"] as? String == "noActiveGoal")
            #expect(store.apply(GoGoalRequest(operation: .clear, expectedRevision: 2, sourceQuote: "Forget my goal"),
                                heard: "Forget my goal")["ok"] as? Bool == true)
            #expect(GoGoalStore(url: url).state == GoGoalState(revision: 3, goal: nil))
            _ = set(store)
            #expect(store.activeGoal != nil)
        }
    }

    @Test func staleRevisionAndMissingOwnerEvidenceCannotChangeGoal() throws {
        try withStore { store, _ in
            _ = set(store)
            let before = store.state
            for (revision, quote, heard) in [(0, "Landscape", "Landscape"), (1, "Landscape", "Hello"), (1, "", "Hello")] {
                let result = store.apply(GoGoalRequest(operation: .update, expectedRevision: revision, sourceQuote: quote), heard: heard)
                #expect(result["ok"] as? Bool == false)
                #expect(store.state == before)
            }
            #expect(store.apply(GoGoalRequest(operation: .clear, expectedRevision: 1, sourceQuote: "Forget"), heard: nil)["ok"] as? Bool == false)
            #expect(store.state == before)
            #expect(!GoGoalRequest.matchesOwner(quote: "land", heard: "landscape"))
        }
    }

    @Test func setReplacesTheGoalAndUpdateCanRenameTheTask() throws {
        try withStore { store, _ in
            _ = set(store)
            let id = store.activeGoal?.id
            _ = store.apply(GoGoalRequest(operation: .update, expectedRevision: 1, sourceQuote: "make it a GIF instead", task: "export a GIF"),
                            heard: "Actually, make it a GIF instead.")
            #expect(store.activeGoal?.task == "export a GIF")
            #expect(store.activeGoal?.id == id)
            _ = store.apply(GoGoalRequest(operation: .set, expectedRevision: 2, sourceQuote: "New goal", task: "rename a file"), heard: "New goal")
            #expect(store.activeGoal?.id != id)
            #expect(store.activeGoal?.rawGoal == "New goal")
        }
    }

    @Test func malformedArgumentsAreRefused() throws {
        #expect(GoGoalRequest(arguments: ["expectedRevision": true]).expectedRevision == nil)
        #expect(GoGoalRequest(arguments: ["expectedRevision": 1.5]).expectedRevision == nil)
        #expect(GoGoalRequest(arguments: ["operation": "rewrite"]).operation == nil)
        try withStore { store, _ in
            _ = set(store)
            let before = store.state
            #expect(store.apply(GoGoalRequest(arguments: ["operation": "rewrite", "sourceQuote": "Tilt it"]), heard: "Tilt it")["error"] as? String == "invalidGoalOperation")
            #expect(store.apply(GoGoalRequest(operation: .set, expectedRevision: 1, sourceQuote: "Tilt it"), heard: "Tilt it")["error"] as? String == "goalNeedsTask")
            #expect(store.state == before)
        }
    }

    @Test func writeAndLoadFailuresDoNotPretendToSave() throws {
        try withStore { store, url in
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            #expect(set(store)["error"] as? String == "goalStoreWriteFailed")
            #expect(store.state.revision == 0)
            #expect(store.activeGoal == nil)
            #expect(GoGoalStore(url: url).apply(GoGoalRequest(operation: .read), heard: nil)["error"] as? String == "goalStoreUnreadable")
        }
    }

    @Test func toolParserKeepsGoalWordsOutOfDecisionLog() {
        let call = RealtimeToolCall.parsed(callID: "goal-1", name: GoGoalTool.name, arguments: [
            "operation": "set", "expectedRevision": 0, "sourceQuote": "My private goal", "task": "rename a file"
        ])
        #expect(call.goalRequest?.operation == .set)
        #expect(call.goalRequest?.expectedRevision == nil)
        #expect(!RealtimeVoiceVerbs.allToolNames.contains(call.name))
    }

    @Test func providerGoalWithoutRevisionSavesWithLocalTurnRevision() throws {
        try withStore { store, url in
            let json = Data(#"{"toolCall":{"functionCalls":[{"id":"g1","name":"go_goal","args":{"operation":"set","task":"make this document portrait","sourceQuote":"make this document portrait"}}]}}"#.utf8)
            let message = try #require(JSONSerialization.jsonObject(with: json) as? [String: Any])
            let request = try #require(RealtimeOpenAppTool.parseGemini(message).first?.goalRequest)
            #expect(request.expectedRevision == nil)
            let result = store.apply(request, heard: "Remember my goal: make this document portrait.", boundRevision: 0)
            #expect(result["ok"] as? Bool == true)
            #expect(GoGoalStore(url: url).activeGoal?.task == "make this document portrait")

            let update = GoGoalRequest(arguments: ["operation": "update",
                                                   "sourceQuote": "change my goal to landscape", "expectedRevision": 99])
            #expect(update.expectedRevision == nil)
            #expect(store.apply(update, heard: "Actually, change my goal to landscape.", boundRevision: 1)["ok"] as? Bool == true)
            #expect(GoGoalStore(url: url).activeGoal?.lastInstruction == "Actually, change my goal to landscape.")
            #expect(store.apply(request, heard: "make this document portrait", boundRevision: 0)["error"] as? String == "goalRevisionChangedReadAgain")
            #expect(store.activeGoal?.lastInstruction == "Actually, change my goal to landscape.")
        }
    }

    @Test func eachVoiceTurnBindsTheCurrentLocalRevision() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = GoGoalStore(url: directory.appendingPathComponent("goal.json"))
        let connection = RealtimeVoiceConnection(harnessAnswer: { _ in "{}" }, goalStore: store)
        try await connection.beginTurn()
        #expect(connection.turn.goalRevision == 0)
        _ = set(store)
        #expect(connection.turn.goalRevision == 0)
        try await connection.beginTurn()
        #expect(connection.turn.goalRevision == 1)
    }
}
