//
//  WorkerConfiguration.swift
//  Go
//
//  The Cloudflare worker's URL and the client key that proves a request came
//  from this app, both read from UserDefaults (see scripts/go-configure-local.py),
//  so neither is in the source or the binary. Without the key the worker would
//  be an open proxy for its API keys.
//

import Foundation

nonisolated enum WorkerConfiguration {
    /// The placeholder a fresh clone ships with; it never resolves.
    static let placeholderBaseURL = "https://your-worker-name.your-subdomain.workers.dev"

    static let baseURLDefaultsKey = "GoWorkerBaseURL"
    static let clientKeyDefaultsKey = "GoWorkerClientKey"
    static let clientKeyHeaderName = "X-Go-Client-Key"

    static var baseURL: String {
        guard let configuredBaseURL = nonEmptyDefault(forKey: baseURLDefaultsKey) else {
            return placeholderBaseURL
        }
        return configuredBaseURL.hasSuffix("/") ? String(configuredBaseURL.dropLast()) : configuredBaseURL
    }

    static var clientKey: String? {
        nonEmptyDefault(forKey: clientKeyDefaultsKey)
    }

    static func routeURL(_ routePath: String) -> URL {
        URL(string: baseURL + routePath)!
    }

    /// Adds the client key header when configured.
    static func attachClientKey(to request: inout URLRequest) {
        if let clientKey {
            request.setValue(clientKey, forHTTPHeaderField: clientKeyHeaderName)
        }
    }

    private static func nonEmptyDefault(forKey defaultsKey: String) -> String? {
        let trimmedValue = UserDefaults.standard.string(forKey: defaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmedValue?.isEmpty ?? true) ? nil : trimmedValue
    }
}
