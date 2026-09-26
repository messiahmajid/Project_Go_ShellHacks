import Foundation

nonisolated struct GoPlanningContext: Codable, Sendable {
    let goal: GoGoal
    let observation: GoObservation
    let verifiedSteps: [GoWalkthroughStep]
    let catalogLimited: Bool
    var screenshotJPEG: String? = nil
    /// The last few minutes, oldest first: earlier requests and what Go pointed
    /// at or did, so "open it" or "do the same there" can be resolved.
    var recent: [String] = []
    /// While a saved routine replays and its next step isn't on this screen:
    /// what that step was, so the planner can find it or the way to it.
    var routineHint: String? = nil
}

@MainActor
enum GoStepPlanner {
    static func plan(_ context: GoPlanningContext) async throws -> GoStepProposal {
        var request = URLRequest(url: WorkerConfiguration.routeURL("/go-plan"))
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        WorkerConfiguration.attachClientKey(to: &request)
        request.httpBody = try JSONEncoder().encode(context)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw GoVoiceFailure(kind: "walkthrough:plannerUnavailable")
        }
        try Task.checkCancellation()
        return try JSONDecoder().decode(GoStepProposal.self, from: data)
    }
}
