import Foundation
import Testing
@testable import Go

private final class DeferredTTSProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var pending: DeferredTTSProtocol?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        Self.pending = self
        Self.lock.unlock()
    }
    override func stopLoading() {}

    static func takePending() -> DeferredTTSProtocol? {
        lock.lock()
        defer { lock.unlock() }
        let request = pending
        pending = nil
        return request
    }

    func finish(status: Int, data: Data) {
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                                       headerFields: ["Content-Type": "audio/mpeg"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}

@MainActor
@Suite(.serialized)
struct ElevenLabsTTSClientTests {
    private func client() -> ElevenLabsTTSClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DeferredTTSProtocol.self]
        return ElevenLabsTTSClient(proxyURL: "https://voice-test.invalid/tts",
                                   session: URLSession(configuration: configuration))
    }
    private func pendingRequest() async throws -> DeferredTTSProtocol {
        for _ in 0..<200 {
            if let request = DeferredTTSProtocol.takePending() { return request }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        throw NSError(domain: "TestRequestTimeout", code: 1)
    }

    @Test func stoppingDuringDownloadPreventsLatePlayback() async throws {
        let tts = client()
        let task = Task { try await tts.speakText("Test reply") }
        let request = try await pendingRequest()
        tts.stopPlayback()
        // Invalid audio must never reach the decoder after this turn was stopped.
        request.finish(status: 200, data: Data([1, 2, 3]))
        do {
            try await task.value
            Issue.record("A stopped reply started playback")
        } catch is CancellationError {
            #expect(!tts.isPlaying)
        } catch {
            Issue.record("The stopped reply reached decoding: \(error)")
        }
    }

    @Test func providerFailureDoesNotStartPlayback() async throws {
        let tts = client()
        let task = Task { try await tts.speakText("Test reply") }
        let request = try await pendingRequest()
        request.finish(status: 402, data: Data("Unavailable voice".utf8))
        do {
            try await task.value
            Issue.record("A failed provider request was accepted")
        } catch {
            #expect((error as NSError).domain == "ElevenLabsTTS")
            #expect((error as NSError).code == 402)
            #expect(!tts.isPlaying)
        }
    }
}
