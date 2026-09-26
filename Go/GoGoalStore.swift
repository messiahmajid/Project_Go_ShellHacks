import Foundation
import Darwin

/// User intent only. This is not evidence that an application changed.
/// Kept in the owner's own words, with no task-specific fields: any
/// requirement ("vertical", "called Receipts") lives in the text itself.
nonisolated struct GoGoal: Codable, Equatable, Sendable {
    enum Status: String, Codable, Sendable { case active, completed }
    let id: UUID
    let rawGoal: String
    var lastInstruction: String
    var task: String
    var status: Status
}

nonisolated struct GoGoalState: Codable, Equatable, Sendable {
    var revision = 0
    var goal: GoGoal?
}

@MainActor
final class GoGoalStore {
    nonisolated static let defaultURL = URL.applicationSupportDirectory
        .appendingPathComponent("Go", isDirectory: true).appendingPathComponent("goal.json")
    private let url: URL
    private(set) var state = GoGoalState()
    private var loadFailed = false
    var activeGoal: GoGoal? { state.goal?.status == .active ? state.goal : nil }

    init(url: URL = GoGoalStore.defaultURL) {
        self.url = url
        if FileManager.default.fileExists(atPath: url.path) {
            do { state = try JSONDecoder().decode(GoGoalState.self, from: Data(contentsOf: url)) }
            catch { loadFailed = true }
        }
    }

    /// Writes first, then publishes the state. A failed write leaves memory unchanged.
    func apply(_ request: GoGoalRequest, heard: String?, boundRevision: Int? = nil) -> [String: Any] {
        func failure(_ code: String) -> [String: Any] { ["ok": false, "error": code, "uiChanged": false] }
        guard !loadFailed else { return failure("goalStoreUnreadable") }
        guard let operation = request.operation else { return failure("invalidGoalOperation") }
        if operation == .read { return result() }
        guard (boundRevision ?? request.expectedRevision) == state.revision else { return failure("goalRevisionChangedReadAgain") }
        guard let heard = heard?.trimmingCharacters(in: .whitespacesAndNewlines), !heard.isEmpty,
              heard.count <= 2_000, let quote = request.sourceQuote,
              GoGoalRequest.matchesOwner(quote: quote, heard: heard) else { return failure("goalNeedsOwnerWords") }
        var next = state
        switch operation {
        case .read: break
        case .set:
            guard let task = request.task, !task.isEmpty, task.count <= 80 else { return failure("goalNeedsTask") }
            next.goal = GoGoal(id: UUID(), rawGoal: heard, lastInstruction: heard, task: task, status: .active)
        case .update:
            guard var goal = activeGoal else { return failure("noActiveGoal") }
            if let task = request.task {
                guard !task.isEmpty, task.count <= 80 else { return failure("invalidGoalTask") }
                goal.task = task
            }
            goal.lastInstruction = heard
            next.goal = goal
        case .clear: next.goal = nil
        case .complete:
            guard activeGoal != nil else { return failure("noActiveGoal") }
            next.goal?.status = .completed
            next.goal?.lastInstruction = heard
        }
        next.revision += 1
        do {
            let directory = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let temporary = directory.appendingPathComponent(".goal-\(UUID().uuidString).json")
            defer { try? FileManager.default.removeItem(at: temporary) }
            guard FileManager.default.createFile(atPath: temporary.path, contents: try JSONEncoder().encode(next),
                                                 attributes: [.posixPermissions: 0o600]),
                  rename(temporary.path, url.path) == 0 else { return failure("goalStoreWriteFailed") }
            state = next
            return result()
        } catch { return failure("goalStoreWriteFailed") }
    }

    private func result() -> [String: Any] {
        let object = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(state))) as? [String: Any] ?? [:]
        return ["ok": true, "revision": state.revision, "goal": object["goal"] ?? NSNull(),
                "uiChanged": false, "message": "Goal record only. No application action or verification occurred."]
    }
}
