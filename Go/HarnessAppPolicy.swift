//
//  HarnessAppPolicy.swift
//  Go
//
//  Optional per-app policy, edited by hand at
//  ~/Library/Application Support/Go/harness-policy.json, e.g.
//  { "default": "allow", "apps": { "com.apple.Terminal": "confirm" } }
//  It is combined with the kernel's decision, never used instead of it.
//

import Foundation

nonisolated enum HarnessAppPolicy {

    enum Verdict: String, Decodable {
        case allow, confirm, refuse
    }

    struct Policy: Decodable, Equatable {
        let defaultVerdict: Verdict
        let apps: [String: Verdict]

        enum CodingKeys: String, CodingKey {
            case defaultVerdict = "default"
            case apps
        }

        init(defaultVerdict: Verdict = .allow, apps: [String: Verdict] = [:]) {
            self.defaultVerdict = defaultVerdict
            self.apps = apps
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            defaultVerdict = try container.decodeIfPresent(Verdict.self, forKey: .defaultVerdict) ?? .allow
            // Keys are lowercased; two keys differing only in case make the file invalid.
            var lowered: [String: Verdict] = [:]
            for (key, verdict) in try container.decodeIfPresent([String: Verdict].self, forKey: .apps) ?? [:] {
                let folded = key.lowercased()
                guard lowered.updateValue(verdict, forKey: folded) == nil else {
                    throw DecodingError.dataCorruptedError(
                        forKey: .apps, in: container,
                        debugDescription: "apps lists \"\(key)\" more than once (keys are case-insensitive)"
                    )
                }
            }
            apps = lowered
        }
    }

    enum Load: Equatable {
        case loaded(Policy, source: String)
        case missing
        /// Fail closed: an unreadable policy never becomes "allow".
        case unreadable(reason: String)
    }

    static func load(from url: URL) -> Load {
        // `lstat`, so a dangling symlink isn't read as "no file".
        do {
            _ = try FileManager.default.attributesOfItem(atPath: url.path)
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
            return .missing
        } catch {
            return .unreadable(reason: "\(url.path): \(error.localizedDescription)")
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            return .unreadable(reason: "\(url.path): \(error.localizedDescription)")
        }
        switch parse(data) {
        case .success(let policy): return .loaded(policy, source: "file")
        case .failure(let failure): return .unreadable(reason: "\(url.path): \(failure.reason)")
        }
    }

    static func parse(_ data: Data) -> Result<Policy, ParseFailure> {
        do {
            return .success(try JSONDecoder().decode(Policy.self, from: data))
        } catch {
            return .failure(ParseFailure(reason: String(describing: error).prefix(200).description))
        }
    }

    struct ParseFailure: Error, Equatable { let reason: String }

    static func verdict(for bundleIdentifier: String?, in policy: Policy) -> (Verdict, source: String) {
        if let bundleIdentifier, let listed = policy.apps[bundleIdentifier.lowercased()] {
            return (listed, "file")
        }
        return (policy.defaultVerdict, "default")
    }

    /// No file on disk: allow.
    static func verdict(for bundleIdentifier: String?, in policy: Policy?) -> (Verdict, source: String) {
        guard let policy else { return (.allow, "missing") }
        return verdict(for: bundleIdentifier, in: policy)
    }

    /// Policy `refuse` beats everything, a kernel refusal beats policy `confirm`,
    /// and `allow` leaves the kernel's decision unchanged.
    static func compose(policy: Verdict, bundleIdentifier: String?, kernel: SafetyDecision) -> SafetyDecision {
        let app = bundleIdentifier ?? "an app with no bundle identifier"
        switch (policy, kernel) {
        case (.refuse, _):
            return .refuse(reason: "app policy refuses \(app)")
        case (.confirm, .refuse):
            return kernel
        case (.confirm, .requireConfirmation(let kernelReason, let destructive)):
            return .requireConfirmation(reason: "app policy requires confirmation for \(app); \(kernelReason)",
                                        destructive: destructive)
        case (.confirm, .allow):
            return .requireConfirmation(reason: "app policy requires confirmation for \(app)")
        case (.allow, _):
            return kernel
        }
    }
}
