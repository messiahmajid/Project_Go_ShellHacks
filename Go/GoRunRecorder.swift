import Foundation

/// Saves real planning moments as test cases, only when switched on
/// (`defaults write <Go's bundle id> goRecordRuns -bool true`; `false` to stop).
///
/// Each file holds what the planner was given (the screen's controls and the
/// screenshot), what it answered, and what Go made of that answer. The unit
/// tests replay every case through Go's own step logic and fail when the result
/// changes, and `scripts/go-replay-planner.mjs` re-asks the planner. Files stay in
/// Go's own folder (owner-only), never in the repo; the latest 200 are kept.
nonisolated enum GoRunRecorder {
    static let defaultsKey = "goRecordRuns"
    static var isOn: Bool { UserDefaults.standard.bool(forKey: defaultsKey) }
    static var directory: URL { HarnessServer.supportDirectory.appendingPathComponent("test-cases", isDirectory: true) }
    static let keep = 200

    /// What Go made of the planner's answer, compared on replay.
    struct Outcome: Codable, Equatable, Sendable {
        let phase: String
        let stepKind: String?
        let target: String?
        let askCode: String?

        init(phase: String, stepKind: String?, target: String?, askCode: String?) {
            self.phase = phase; self.stepKind = stepKind; self.target = target; self.askCode = askCode
        }

        init(_ state: GoWalkthroughState) {
            phase = state.phase.rawValue
            stepKind = state.step?.kindLabel
            target = state.step?.signature
            askCode = state.phase == .needsInput ? state.askCode : nil
        }
    }

    struct Case: Codable, Sendable {
        var version = 1
        let recordedAt: Date
        /// Exactly what the planner was sent.
        let context: GoPlanningContext
        /// The full reading Go turned the answer into a step from.
        let observation: GoObservation
        let proposal: GoStepProposal
        let outcome: Outcome
    }

    /// Replays a case through Go's step logic, as it runs now.
    static func replay(_ recorded: Case) -> Outcome {
        var state = GoWalkthroughState(replaying: recorded.context.verifiedSteps)
        state.accept(recorded.proposal, from: recorded.observation)
        return Outcome(state)
    }

    static func record(context: GoPlanningContext, observation: GoObservation, proposal: GoStepProposal,
                       state: GoWalkthroughState) {
        guard isOn else { return }
        let entry = Case(recordedAt: Date(), context: context, observation: observation, proposal: proposal, outcome: Outcome(state))
        let folder = directory
        Task.detached(priority: .utility) {
            let files = FileManager.default
            try? files.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            guard let data = try? JSONEncoder().encode(entry) else { return }
            let stamp = Int(entry.recordedAt.timeIntervalSince1970 * 1000)
            let app = entry.observation.app.split(separator: ".").last.map(String.init) ?? "app"
            let file = folder.appendingPathComponent("\(stamp)-\(app).json")
            files.createFile(atPath: file.path, contents: data, attributes: [.posixPermissions: 0o600])
            // Only the newest cases are kept.
            let all = ((try? files.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
            for old in all.dropLast(keep) { try? files.removeItem(at: old) }
        }
    }

    /// Accepts the current result as the expected one (for an intended change).
    static func rebaseline(_ name: String, to outcome: Outcome) {
        let file = directory.appendingPathComponent(name)
        guard let data = try? Data(contentsOf: file), let entry = try? JSONDecoder().decode(Case.self, from: data),
              let updated = try? JSONEncoder().encode(Case(recordedAt: entry.recordedAt, context: entry.context,
                                                          observation: entry.observation, proposal: entry.proposal, outcome: outcome))
        else { return }
        try? updated.write(to: file, options: .atomic)
    }

    /// Every saved case, oldest first, with its file name.
    static func saved() -> [(name: String, case: Case)] {
        let files = ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        return files.compactMap { url in
            guard let data = try? Data(contentsOf: url), let entry = try? JSONDecoder().decode(Case.self, from: data) else { return nil }
            return (url.lastPathComponent, entry)
        }
    }
}
