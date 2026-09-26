import Foundation

nonisolated struct GoPlanningContext: Codable, Sendable {
    let goal: GoGoal
    let observation: GoObservation
    let verifiedSteps: [GoWalkthroughStep]
    let catalogLimited: Bool
    /// Every step finished for this goal before `verifiedSteps`, oldest first, one
    /// short line each, so a long task never loses what it already did.
    var earlierSteps: [String] = []
    /// The planner's own notes for this goal: what it saw on earlier screens that
    /// later steps need. Screen content, like the screenshot: sent to plan, kept
    /// in memory for the goal only, never logged or saved.
    var notes: [String] = []
    /// The planner's private checklist for this goal (parts and facts to find),
    /// sent back each time so it can tick lines off. Never spoken or shown.
    var checklist: [String] = []
    /// The owner's question about the step being shown, and that step, when Go
    /// asks the planner to answer it rather than plan.
    var ownerQuestion: String? = nil
    var currentStep: String? = nil
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
