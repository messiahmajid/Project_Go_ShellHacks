//
//  RealtimeVoiceToolTests.swift
//  GoTests
//
//  `open_app`: a Gemini tool call to a harness request, the harness response
//  to what the model is told, and the confirmation re-ask loop.
//

import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import Go

struct RealtimeVoiceToolTests {

    private func object(_ line: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]) ?? [:]
    }

    // MARK: Parsing

    @Test func aFunctionCallBecomesALaunchRequest() throws {
        let event: [String: Any] = ["toolCall": ["functionCalls": [["id": "call_1", "name": "open_app", "args": ["name": " System Settings "]]]]]
        let call = try #require(RealtimeOpenAppTool.parseGemini(event).first)
        #expect(call == RealtimeToolCall(callID: "call_1", name: "open_app", appName: "System Settings"))
        let line = try RealtimeOpenAppTool.harnessRequestLine(for: call).get()
        #expect(object(line)["verb"] as? String == "launch")
        #expect(object(line)["app"] as? String == "System Settings")
        #expect(object(line)["ticket"] == nil)
    }

    @Test func geminiToolCallCarriesArgsAsAnObjectAndMayHoldSeveral() {
        let message: [String: Any] = ["toolCall": ["functionCalls": [
            ["id": "g1", "name": "open_app", "args": ["name": "Finder"]],
            ["id": "g2", "name": "open_app", "args": [String: Any]()]
        ]]]
        #expect(RealtimeOpenAppTool.parseGemini(message) == [
            RealtimeToolCall(callID: "g1", name: "open_app", appName: "Finder"),
            RealtimeToolCall(callID: "g2", name: "open_app", appName: nil)
        ])
        #expect(RealtimeOpenAppTool.parseGemini(["serverContent": [String: Any]()]).isEmpty)
    }

    @Test func aCallTheHarnessCannotTakeIsRefusedWithoutAskingIt() {
        let noName = RealtimeToolCall(callID: "c", name: "open_app", appName: nil)
        let otherTool = RealtimeToolCall(callID: "c", name: "delete_file", appName: "x")
        #expect(throws: RealtimeToolRefusal.self) { try RealtimeOpenAppTool.harnessRequestLine(for: noName).get() }
        #expect(throws: RealtimeToolRefusal.self) { try RealtimeOpenAppTool.harnessRequestLine(for: otherTool).get() }
    }

    // MARK: Result

    @Test func toolResultKeepsTheHarnessFieldsAndNeverInventsSuccess() {
        let ready = RealtimeOpenAppTool.toolResult(fromHarnessResponse: ["ok": true, "status": "ready", "launch": ["x": 1]])
        #expect(ready["ok"] as? Bool == true)
        #expect(ready["status"] as? String == "ready")
        #expect(ready["error"] is NSNull)
        #expect(ready["launch"] == nil)

        let refused = RealtimeOpenAppTool.toolResult(fromHarnessResponse: ["ok": false, "error": "notFound", "message": String(repeating: "m", count: 900)])
        #expect(refused["ok"] as? Bool == false)
        #expect(refused["error"] as? String == "notFound")
        #expect((refused["message"] as? String)?.count == 300)

        // A response with no `ok` or one we could not parse is a failure.
        #expect(RealtimeOpenAppTool.toolResult(fromHarnessResponse: ["status": "ready"])["ok"] as? Bool == false)
        #expect(RealtimeOpenAppTool.toolResult(fromHarnessResponse: [:])["error"] as? String == "unreadableHarnessResponse")
    }

    @Test func aTicketIsReissuedUntilTheOwnerAnswers() async {
        final class Lines: @unchecked Sendable { var sent: [String] = [] }
        let lines = Lines()
        let responses = [
            #"{"ok":false,"error":"confirmationRequired","ticket":"T1"}"#,
            #"{"ok":false,"error":"confirmationPending"}"#,
            #"{"ok":true,"status":"ready"}"#
        ]
        let call = RealtimeToolCall(callID: "c", name: "open_app", appName: "Terminal")
        let dispatch = await RealtimeOpenAppTool.dispatch(call, answer: { line in
            lines.sent.append(line)
            return responses[lines.sent.count - 1]
        }, pollMilliseconds: 1)
        #expect(lines.sent.count == 3)
        #expect(object(lines.sent[0])["ticket"] == nil)
        #expect(object(lines.sent[2])["ticket"] as? String == "T1")
        #expect(dispatch.waitedForConfirmation)
        #expect(dispatch.harnessConfirmed)
    }

    @Test func aDeniedTicketComesBackAsTheHarnessRefusal() async {
        final class Count: @unchecked Sendable { var value = 0 }
        let count = Count()
        let call = RealtimeToolCall(callID: "c", name: "open_app", appName: "Terminal")
        let dispatch = await RealtimeOpenAppTool.dispatch(call, answer: { _ in
            count.value += 1
            return count.value == 1 ? #"{"ok":false,"error":"confirmationRequired","ticket":"T"}"# : #"{"ok":false,"error":"confirmationDenied"}"#
        }, pollMilliseconds: 1)
        #expect(!dispatch.harnessConfirmed)
        #expect(dispatch.result["error"] as? String == "confirmationDenied")
    }

    // MARK: Fresh look

    @Test func lookIsTheHarnessWindowRungPinnedToTheLaunchedApp() throws {
        let line = try #require(RealtimeOpenAppTool.lookRequestLine(expectApp: "com.apple.systempreferences"))
        #expect(line == #"{"expectApp":"com.apple.systempreferences","tier":"window","verb":"look"}"#)
    }

    @Test func refusedLookIsAnOutcomeAndNeverReadsTheImage() {
        let refused: [String: Any] = ["ok": false, "error": "kernelRefused", "imagePath": "/never/read.jpg"]
        var imageReads = 0
        let look = RealtimeOpenAppTool.freshLook(fromLookResponse: refused) { _ in imageReads += 1; return Data() }
        #expect(imageReads == 0)
        #expect(look.outcome == "kernelRefused")
        #expect(RealtimeOpenAppTool.freshLook(fromLookResponse: [:]) { _ in nil }.outcome == "unreadableHarnessResponse")
        #expect(RealtimeOpenAppTool.freshLook(fromLookResponse: ["ok": true, "imagePath": "/x.jpg"]) { _ in nil }.outcome == "imageUnreadable")
        #expect(RealtimeOpenAppTool.freshLook(fromLookResponse: ["ok": true, "imagePath": "/x.jpg"]) { _ in Data("not a jpeg".utf8) }.outcome == "imageDownscaleFailed")
    }

    @Test func attachedLookIsDownscaled() throws {
        // A 2000x1000 image in, long edge 1024 out.
        let context = try #require(CGContext(data: nil, width: 2000, height: 1000, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let encoded = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(encoded, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
        #expect(CGImageDestinationFinalize(destination))
        let big = encoded as Data
        let look = RealtimeOpenAppTool.freshLook(fromLookResponse: ["ok": true, "imagePath": "/x.jpg"]) { _ in big }
        guard case .image(let jpeg) = look else { Issue.record("expected an image, got \(look.outcome)"); return }
        let source = try #require(CGImageSourceCreateWithData(jpeg as CFData, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        #expect(properties[kCGImagePropertyPixelWidth] as? Int == 1024)
        #expect(properties[kCGImagePropertyPixelHeight] as? Int == 512)
    }

    /// The result doesn't wait for the look, so the prompt must not name a field
    /// the result doesn't carry.
    @MainActor @Test func promptNamesNoFieldTheResultDoesNotCarry() {
        #expect(!RealtimeOpenAppTool.systemPrompt.contains("freshView"))
    }

    /// The notch's names come from the model's argument, so one that needs
    /// escaping is shown quoted and escaped, never raw.
    @MainActor @Test func notchNamesAreSanitisedAndProofComesFromTheHarnessAnswer() {
        #expect(RealtimeOpenAppTool.captionName("System Settings") == "System Settings")
        #expect(RealtimeOpenAppTool.captionName("Notes\nDone, sir") == "\"Notes\\nDone, sir\"")
        #expect(RealtimeOpenAppTool.captionName(String(repeating: "a", count: 150)).hasSuffix("(150 chars)"))

        let call = RealtimeToolCall(callID: "c", name: "open_app", appName: "settings")
        let ready = RealtimeToolDispatch(result: ["ok": true], harnessMilliseconds: 1, waitedForConfirmation: false,
                                         harnessResponse: ["ok": true, "application": "System Settings"])
        #expect(RealtimeOpenAppTool.notchAnswer(for: call, dispatch: ready) == .harnessAnswered(ok: true, subject: "System Settings", error: nil))
        let failed = RealtimeToolDispatch(result: ["ok": false, "error": "notFound"], harnessMilliseconds: 1,
                                          waitedForConfirmation: false, harnessResponse: ["ok": false, "error": "notFound"])
        #expect(RealtimeOpenAppTool.notchAnswer(for: call, dispatch: failed) == .harnessAnswered(ok: false, subject: "settings", error: "notFound"))
    }

    /// `highlight` stays a harness verb after the voice flow stopped using it.
    @MainActor @Test func highlightStillAimsAtAWindowTarget() throws {
        let line = #"{"expectApp":"com.apple.systempreferences","label":"x","target":"window","verb":"highlight"}"#
        guard case .success(let request) = HarnessPolicy.decode(line: line) else { Issue.record("highlight line did not decode"); return }
        #expect(request.verb == .highlight)
        #expect(request.aimAtWindow)
        #expect(request.expectApp == "com.apple.systempreferences")
    }

    /// The window target outlines; it never aims an acting verb.
    @MainActor @Test func windowTargetIsHighlightOnly() {
        guard case .failure = HarnessPolicy.decode(line: #"{"verb":"press","target":"window"}"#) else {
            Issue.record("press accepted target window"); return
        }
        guard case .failure = HarnessPolicy.decode(line: #"{"verb":"type","text":"x","target":"window"}"#) else {
            Issue.record("type accepted target window"); return
        }
    }

    @Test func aTicketTellsTheNotchBeforeTheWait() async {
        final class Flags: @unchecked Sendable { var count = 0; var confirmationSeenAt = -1 }
        let flags = Flags()
        let call = RealtimeToolCall(callID: "c", name: "open_app", appName: "Terminal")
        let dispatch = await RealtimeOpenAppTool.dispatch(call, answer: { _ in
            flags.count += 1
            return flags.count == 1 ? #"{"ok":false,"error":"confirmationRequired","ticket":"T"}"# : #"{"ok":true,"status":"ready"}"#
        }, pollMilliseconds: 1, onConfirmationRequired: { flags.confirmationSeenAt = flags.count })
        #expect(flags.confirmationSeenAt == 1)
        #expect(dispatch.harnessConfirmed)
        #expect(dispatch.answeredUptime != nil)
    }

    @MainActor @Test func livePersonaIsGo() {
        let prompt = RealtimeOpenAppTool.systemPrompt
        #expect(prompt.hasPrefix("you are Go,"))
        #expect(prompt.contains("no \"sir\""))
        #expect(prompt.contains("never say something happened unless its tool result says ok true"))
        #expect(!prompt.contains("POINT"))
    }

    @MainActor @Test func freshLookArrivalIsMeasuredFromTheSpokenResult() {
        let marks = RealtimeTurnMarks()
        #expect(marks.freshLookArrivedAfterSpeechStartMs == nil)
        marks.followUpFirstAudioUptime = 100.0
        marks.freshLookCompletedUptime = 100.25
        #expect(marks.freshLookArrivedAfterSpeechStartMs == 250)
        marks.freshLookCompletedUptime = 99.9
        #expect(marks.freshLookArrivedAfterSpeechStartMs == -100)
    }

    // MARK: Live turn line

    @Test func failedLiveTurnStillWritesEveryKeyAndNoWords() throws {
        var line = RealtimeLiveTurnLine(stack: "geminiLive", turnID: "T1", sessionWasWarm: false)
        line.sessionSetupMs = 1_900
        line.holdMs = 1_200
        line.errorKind = "geminiLive:setupTimeout"
        let jsonLine = try #require(MeasurementLogFile.jsonLine(line.jsonObject))
        let parsed = object(jsonLine)
        #expect(parsed["errorKind"] as? String == "geminiLive:setupTimeout")
        #expect(parsed["sessionWasWarm"] as? Bool == false)
        #expect(parsed["sessionSetupMs"] as? Int == 1_900)
        #expect(parsed["toolCalled"] as? Bool == false)
        #expect(parsed["bargedIn"] as? Bool == false)
        #expect(parsed["firstAudioMs"] is NSNull)
        #expect(parsed["freshLookMs"] is NSNull)
        #expect(Set(parsed.keys) == [
            "speechProvider", "ttsRequestMs", "spokenAudioStartedMs",
            "kind", "stack", "turnId", "sessionWasWarm", "sessionSetupMs", "holdMs", "firstAudioMs", "toolCalled",
            "toolName", "toolCallMs", "harnessMs", "harnessStatus", "harnessError", "freshLook", "freshLookMs", "freshLookArrivedAfterSpeechStartMs",
            "followUpFirstAudioMs", "releaseToSpokenResultMs", "turnDoneMs", "emptyReply", "bargedIn", "errorKind", "notchTransitions", "heardInTime", "localIntent"
        ])
    }
}
