//
//  ElevenLabsTTSClient.swift
//  Go
//
//  Fetches one short ElevenLabs reply through the worker and plays it. When
//  ElevenLabs can't (no credits, a rejected key, no network), the same words
//  are spoken by the built-in macOS voice, so a speech outage never stops a task.
//

import AVFoundation
import Foundation

@MainActor
final class ElevenLabsTTSClient {
    private let proxyURL: URL
    private let session: URLSession

    /// The audio player for the current TTS playback. Kept alive so the
    /// audio finishes playing even if the caller doesn't hold a reference.
    private var audioPlayer: AVAudioPlayer?
    private var playbackGeneration = 0
    private let systemVoice = AVSpeechSynthesizer()
    /// After an account error (rejected key, no credits, rate limit), ElevenLabs
    /// is skipped until then, so each sentence doesn't wait on a failing request.
    private var skipProviderUntil: Date?
    /// Why the last sentence was spoken by the system voice, for the turn log; nil
    /// when ElevenLabs spoke it.
    private(set) var lastFallbackReason: String?

    /// Stands in for the system voice (tests, so the machine running them stays quiet).
    private let systemVoiceOverride: ((String) -> Void)?

    init(proxyURL: String, session: URLSession? = nil, systemVoice: ((String) -> Void)? = nil) {
        self.proxyURL = URL(string: proxyURL)!
        self.systemVoiceOverride = systemVoice

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        self.session = session ?? URLSession(configuration: configuration)
    }

    /// Speaks `text` with ElevenLabs, or the system voice when ElevenLabs fails.
    /// Throws only on cancellation.
    func speakText(_ text: String) async throws {
        playbackGeneration += 1
        let generation = playbackGeneration
        if let until = skipProviderUntil, Date() < until {
            speakWithSystemVoice(text)
            return
        }
        do {
            try await speakWithProvider(text, generation: generation)
            lastFallbackReason = nil
        } catch {
            if error is CancellationError || Task.isCancelled || generation != playbackGeneration { throw CancellationError() }
            let code = (error as NSError).domain == "ElevenLabsTTS" ? (error as NSError).code : 0
            if [401, 402, 403, 429].contains(code) { skipProviderUntil = Date().addingTimeInterval(300) }
            lastFallbackReason = code > 0 ? "http\(code)" : "unreachable"
            print("⚠️ ElevenLabs TTS failed (\(lastFallbackReason ?? "?")); using the system voice")
            speakWithSystemVoice(text)
        }
    }

    private func speakWithSystemVoice(_ text: String) {
        audioPlayer?.stop()
        audioPlayer = nil
        systemVoice.stopSpeaking(at: .immediate)
        if lastFallbackReason == nil { lastFallbackReason = "skipped" }
        let spoken = GoSpeechText.spoken(text)
        if let systemVoiceOverride { systemVoiceOverride(spoken); return }
        systemVoice.speak(AVSpeechUtterance(string: spoken))
    }

    private func speakWithProvider(_ text: String, generation: Int) async throws {
        var request = URLRequest(url: proxyURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("audio/mpeg", forHTTPHeaderField: "Accept")
        WorkerConfiguration.attachClientKey(to: &request)

        let body: [String: Any] = [
            "text": GoSpeechText.spoken(text),
            "model_id": "eleven_flash_v2_5",
            "voice_settings": [
                "stability": 0.5,
                "similarity_boost": 0.75
            ]
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(domain: "ElevenLabsTTS", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Invalid response"])
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw NSError(domain: "ElevenLabsTTS", code: httpResponse.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "TTS API error (\(httpResponse.statusCode)): \(errorBody)"])
        }

        try Task.checkCancellation()
        guard generation == playbackGeneration else { throw CancellationError() }

        let player = try AVAudioPlayer(data: data)
        self.audioPlayer = player
        guard player.play() else {
            throw NSError(domain: "ElevenLabsTTS", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "Audio playback did not start"])
        }
        print("🔊 ElevenLabs TTS: playing \(data.count / 1024)KB audio")
    }

    /// Whether speech is currently playing, from either voice.
    var isPlaying: Bool {
        (audioPlayer?.isPlaying ?? false) || systemVoice.isSpeaking
    }

    /// Stops any in-progress playback immediately.
    func stopPlayback() {
        playbackGeneration += 1
        audioPlayer?.stop()
        audioPlayer = nil
        systemVoice.stopSpeaking(at: .immediate)
    }
}
