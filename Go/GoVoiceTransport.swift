import Foundation

//  The connection plumbing Go's voice uses: a WebSocket wrapper, a settle-once
//  waiter, the failure type whose kinds go into the logs, and the voice
//  service's endpoints.

nonisolated struct GoVoiceFailure: Error {
    let kind: String
}

extension GoVoiceFailure {
    /// Stage, then domain and code only. A server's error text can carry anything,
    /// and nothing in this log may carry text we did not write.
    static func kind(for error: Error, stage: String) -> String {
        if let benchFailure = error as? GoVoiceFailure {
            return benchFailure.kind
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .cannotFindHost, .dnsLookupFailed: return "\(stage):dns"
            case .timedOut: return "\(stage):timeout"
            case .notConnectedToInternet, .networkConnectionLost: return "\(stage):offline"
            default: return "\(stage):urlError\(urlError.code.rawValue)"
            }
        }
        let nsError = error as NSError
        return "\(stage):\(nsError.domain)#\(nsError.code)"
    }
}

/// A value that arrives from a WebSocket callback, awaited with a deadline.
/// First settle wins, so a late message cannot overwrite a timeout and a
/// timeout cannot overwrite a message that already arrived.
@MainActor
final class GoWaiter<Value> {
    private var settledResult: Result<Value, Error>?
    private var waitingContinuation: CheckedContinuation<Value, Error>?

    func settle(_ result: Result<Value, Error>) {
        guard settledResult == nil else { return }
        settledResult = result
        waitingContinuation?.resume(with: result)
        waitingContinuation = nil
    }

    func value(timeoutSeconds: Double, timeoutKind: String) async throws -> Value {
        if let settledResult {
            return try settledResult.get()
        }
        let timeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(timeoutSeconds))
            guard !Task.isCancelled else { return }
            self?.settle(.failure(GoVoiceFailure(kind: timeoutKind)))
        }
        defer { timeoutTask.cancel() }
        return try await withCheckedThrowingContinuation { continuation in
            if let settledResult {
                continuation.resume(with: settledResult)
            } else {
                waitingContinuation = continuation
            }
        }
    }
}

@MainActor
final class GoWebSocket {
    let task: URLSessionWebSocketTask
    private var receiveLoop: Task<Void, Never>?

    init(request: URLRequest, session: URLSession) {
        task = session.webSocketTask(with: request)
    }

    /// Reads until the socket ends. Each JSON message is handed over with the
    /// uptime it arrived at, taken before any parsing, so parse cost is not latency.
    func start(
        onMessage: @escaping @MainActor @Sendable ([String: Any], TimeInterval) -> Void,
        onEnd: @escaping @MainActor @Sendable (Error) -> Void
    ) {
        task.resume()
        receiveLoop = Task { @MainActor [task] in
            do {
                while true {
                    let message = try await task.receive()
                    let arrivalUptime = ProcessInfo.processInfo.systemUptime
                    let messageData: Data
                    switch message {
                    case .string(let text): messageData = Data(text.utf8)
                    // Gemini sends its JSON in binary frames.
                    case .data(let data): messageData = data
                    @unknown default: continue
                    }
                    guard let messageObject = try? JSONSerialization.jsonObject(with: messageData) as? [String: Any] else {
                        continue
                    }
                    onMessage(messageObject, arrivalUptime)
                }
            } catch {
                onEnd(error)
            }
        }
    }

    func sendJSON(_ messageObject: [String: Any]) async throws {
        let messageData = try JSONSerialization.data(withJSONObject: messageObject)
        try await task.send(.string(String(decoding: messageData, as: UTF8.self)))
    }

    /// A refused handshake surfaces as a generic URLError; the HTTP status says why.
    /// A socket the server closed carries a close code instead.
    func failureKind(for error: Error, stage: String) -> String {
        if let statusCode = (task.response as? HTTPURLResponse)?.statusCode, statusCode != 101 {
            return "\(stage):http\(statusCode)"
        }
        if task.closeCode != .invalid {
            if let closeReason = task.closeReason {
                // Console only, never the log: the reason is the server's text.
                print("🧪 voice bench: \(stage) closed \(task.closeCode.rawValue): \(String(decoding: closeReason, as: UTF8.self))")
            }
            return "\(stage):close\(task.closeCode.rawValue)"
        }
        return GoVoiceFailure.kind(for: error, stage: stage)
    }

    func close() {
        receiveLoop?.cancel()
        task.cancel(with: .normalClosure, reason: nil)
    }
}

nonisolated enum GoVoiceService {
    static let geminiLiveModel = "gemini-3.1-flash-live-preview"
    /// What Gemini Live takes from the mic (PCM16 mono) and what it answers with.
    static let inputSampleRate = 16_000
    static let outputSampleRate = 24_000
    static let geminiLiveConstrainedURL = "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContentConstrained"

    static let urlSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        return URLSession(configuration: configuration)
    }()

    /// A POST to one of the voice service's routes, with Go's client key.
    private static func postToWorker(routePath: String, jsonBody: [String: Any], stage: String) async throws -> URLSession.AsyncBytes {
        var request = URLRequest(url: WorkerConfiguration.routeURL(routePath))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        WorkerConfiguration.attachClientKey(to: &request)
        request.httpBody = try JSONSerialization.data(withJSONObject: jsonBody)
        let (responseBytes, response) = try await urlSession.bytes(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200...299).contains(statusCode) else {
            responseBytes.task.cancel()
            throw GoVoiceFailure(kind: "\(stage):http\(statusCode)")
        }
        return responseBytes
    }

    static func fetchWorkerJSON(routePath: String, stage: String) async throws -> [String: Any] {
        let responseBytes = try await postToWorker(routePath: routePath, jsonBody: [:], stage: stage)
        var responseData = Data()
        for try await byte in responseBytes {
            responseData.append(byte)
        }
        guard let responseObject = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any] else {
            throw GoVoiceFailure(kind: "\(stage):badJSON")
        }
        return responseObject
    }
}
