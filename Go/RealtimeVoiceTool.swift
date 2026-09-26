//
//  RealtimeVoiceTool.swift
//  Go
//
//  The `open_app` voice tool and the logic every voice tool shares: turning a
//  Gemini Live function call into a harness request, and the harness answer
//  into the result the model hears. The model only states an intention; the
//  harness decides whether and how it runs. Other tools are in
//  `RealtimeVoiceVerbs.swift`.
//

import Foundation
import ImageIO

// MARK: - The tool

/// One function call, normalised. `appName` is nil when the arguments had no
/// usable name; the call is still answered, with an error.
nonisolated struct RealtimeToolCall: Equatable, Sendable {
    let callID: String
    let name: String
    let appName: String?
    var words: String? = nil
    var path: [String]? = nil
    var goalRequest: GoGoalRequest? = nil
    var walkthroughRequest: GoWalkthroughRequest? = nil

    static func parsed(callID: String, name: String, arguments: [String: Any]?) -> RealtimeToolCall {
        if name == GoWalkthroughTool.name {
            return RealtimeToolCall(callID: callID, name: name, appName: nil, walkthroughRequest: GoWalkthroughRequest(arguments))
        }
        if name == GoGoalTool.name {
            return RealtimeToolCall(callID: callID, name: name, appName: nil, goalRequest: GoGoalRequest(arguments: arguments))
        }
        func text(_ value: Any?) -> String? {
            guard let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
            return text
        }
        let words = text(arguments?["words"]) ?? (arguments?["words"] as? [String]).flatMap { text($0.joined(separator: " ")) }
        let path = (arguments?["path"] as? [Any])?.compactMap { $0 as? String }
        return RealtimeToolCall(callID: callID, name: name, appName: text(arguments?["name"]) ?? text(arguments?["app"]),
                                words: words, path: path)
    }
}

nonisolated enum RealtimeOpenAppTool {
    static let name = "open_app"
    static let toolDescription = "Opens an installed macOS app by name and brings it to the front. "
        + "Use the app's name as it appears in the Applications folder, for example \"System Settings\" or \"Finder\"."
    static let argumentDescription = "The app's exact name, for example \"System Settings\"."

    /// How long a pending confirmation is re-asked before giving up.
    static let confirmationWaitSeconds: Double = 60
    static let confirmationPollMilliseconds = 500

    /// The live persona. Examples are deliberately varied (the model copies a
    /// shared shape), completion words wait for an ok tool result, and menu
    /// presses must use a path find_menu_items returned.
    static let systemPrompt = """
    you are Go, a friendly companion on the user's mac. they speak by push-to-talk; you see their screen; replies are spoken.

    manner: warm, relaxed, curious, and useful. use natural contractions and everyday words. no formal titles, no "sir", no canned service phrases. sound like a thoughtful teammate sitting beside them. light humor is welcome when it fits, but never at their expense. answer a greeting warmly and briefly. default to one short sentence, under twenty words; add a second only when it helps. give longer explanations when asked. start with the useful answer. no lists, symbols or markdown.

    evidence: never say something happened unless its tool result says ok true. if ok is false, or the result says notObserved, say it didn't take and give the reason in a few words. if unsure what is on screen, say so. after a tool call, report only the verified outcome, briefly; do not describe the new screen until you have been given a view of it.

    consequences: when a tool result carries a preview, say what will change first: what, where, whether it can be undone. if a confirmation card is showing, say so and wait; only their click decides, never their voice. if refused, give the reason plainly and say where they can do it themselves. never repeat a warning.

    tools: open_app opens an installed app by name, as it appears in the applications folder; an open request always goes through open_app, even when the app already looks open: the harness checks, and for a running app it answers at once. focus_app brings a running app to the front.

    menus: for a command in an app's menu bar, such as a view, a new window, or showing a bar, first call find_menu_items with the app and a few words, then press_menu with one of the paths it returned, copied exactly. never invent or change a path; if none fits, say so and press nothing. menus belong to the app in front, so focus_app first when it is not.

    if a tool returns heardNamedMismatch or ambiguousApp, ask the owner which app they meant, briefly; never focus or open an app to check first.

    words like done, opened, ready or there it is are for after an ok true result from open_app, focus_app or press_menu in this turn, never before and never without one; find_menu_items only looks. for anything else on screen (clicking, typing, anything inside an app), never say you can't: save the goal with go_goal set and call go_walkthrough start, and Go guides it step by step.

    do not reuse the wording of these examples; vary it.
    - owner: open calendar. [tool ok] you: there it is, calendar.
    - owner: open figma. [ok false, notFound] you: that didn't take; nothing called figma is installed.
    - owner: open terminal. [confirmationRequired] you: terminal can run commands, so please approve it on the card first.
    - owner: what's this window? you: downloads, in finder, twelve files. looking for one in particular?
    - owner: turn off wifi. you: wifi controls aren't connected yet. open control centre, top right.
    - owner: put finder in list view. [find_menu_items, then press_menu ok] you: list view, as asked.
    - owner: make the text in textedit rainbow. [find_menu_items, nothing fits] you: nothing in textedit's menus does that.
    """

    /// Lowercased with punctuation and extra spacing removed, for comparing phrases.
    static func normalisedAnswer(_ text: String) -> String {
        text.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
            .unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
            .reduce(into: "") { $0.append($1) }
            .split(separator: " ").joined(separator: " ")
    }

    /// Gemini Live `setup.tools` entry.
    static var geminiDeclaration: [String: Any] {
        [
            "functionDeclarations": [[
                "name": name,
                "description": toolDescription,
                "parameters": [
                    "type": "OBJECT",
                    "properties": ["name": ["type": "STRING", "description": argumentDescription]],
                    "required": ["name"]
                ]
            ]]
        ]
    }

    // MARK: Parsing

    /// Gemini's `toolCall.functionCalls[]`; one message may hold several calls.
    static func parseGemini(_ message: [String: Any]) -> [RealtimeToolCall] {
        guard let functionCalls = (message["toolCall"] as? [String: Any])?["functionCalls"] as? [[String: Any]] else { return [] }
        return functionCalls.compactMap { functionCall in
            guard let callID = functionCall["id"] as? String,
                  let functionName = functionCall["name"] as? String else { return nil }
            return RealtimeToolCall.parsed(callID: callID, name: functionName, arguments: functionCall["args"] as? [String: Any])
        }
    }

    // MARK: Harness round trip

    /// The harness request for a call, or a result to return without asking.
    /// Each tool maps to one verb (open_app → launch, focus_app → focus,
    /// find_menu_items → menus, press_menu → menu); menu verbs carry `expectApp`.
    static func harnessRequestLine(for call: RealtimeToolCall, ticket: String? = nil,
                                   expectApp: String? = nil) -> Result<String, RealtimeToolRefusal> {
        func refuse(_ error: String, _ message: String) -> Result<String, RealtimeToolRefusal> {
            .failure(RealtimeToolRefusal(error: error, message: message))
        }
        guard let appName = call.appName else {
            return RealtimeVoiceVerbs.allToolNames.contains(call.name)
                ? refuse("missingAppName", "\(call.name) needs the app's name")
                : refuse("unknownTool", "there is no tool named \(call.name)")
        }
        var request: [String: Any]
        switch call.name {
        case name:
            request = ["verb": "launch", "app": appName]
        case RealtimeVoiceVerbs.focusAppName:
            request = ["verb": "focus", "app": appName]
        case RealtimeVoiceVerbs.findMenuItemsName:
            guard call.words != nil else { return refuse("missingWords", "find_menu_items needs a few words to look for") }
            request = ["verb": "menus", "expectApp": expectApp ?? appName]
        case RealtimeVoiceVerbs.pressMenuName:
            guard let path = call.path, !path.isEmpty else { return refuse("missingMenuPath", "press_menu needs a path from find_menu_items") }
            // Private menus (Open Recent, History) are never offered or pressed.
            guard !RealtimeVoiceVerbs.isPrivateMenuPath(path) else {
                return refuse("privateMenuItem", "that menu item names the owner's files or pages; it is private and is not offered or pressed")
            }
            request = ["verb": "menu", "path": path, "expectApp": expectApp ?? appName]
        default:
            return refuse("unknownTool", "there is no tool named \(call.name)")
        }
        if let ticket { request["ticket"] = ticket }
        guard let data = try? JSONSerialization.data(withJSONObject: request, options: [.sortedKeys]) else {
            return .failure(RealtimeToolRefusal(error: "requestEncodingFailed", message: "the request could not be encoded"))
        }
        return .success(String(decoding: data, as: UTF8.self))
    }

    static func harnessResponseObject(_ responseLine: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(responseLine.utf8)) as? [String: Any]) ?? [:]
    }

    /// What the model is told: only the harness's own fields. An unreadable
    /// response is a failure.
    static func toolResult(fromHarnessResponse response: [String: Any]) -> [String: Any] {
        guard !response.isEmpty else {
            return ["ok": false, "status": NSNull(), "error": "unreadableHarnessResponse", "message": NSNull()]
        }
        let message = (response["message"] as? String).map { String($0.prefix(300)) }
        return [
            "ok": response["ok"] as? Bool ?? false,
            "status": (response["status"] as? String) ?? NSNull(),
            "error": (response["error"] as? String) ?? NSNull(),
            "message": message ?? NSNull(),
            "verification": ((response["verification"] as? [String: Any])?["status"] as? String) ?? NSNull()
        ]
    }

    static func toolResult(for refusal: RealtimeToolRefusal) -> [String: Any] {
        ["ok": false, "status": NSNull(), "error": refusal.error, "message": refusal.message]
    }

    /// Runs one call through the harness, re-asking with the ticket until the user
    /// answers. `answer` blocks, so this is only called from a detached task.
    static func dispatch(
        _ call: RealtimeToolCall,
        answer: @escaping @Sendable (String) -> String,
        confirmationWaitSeconds: Double = confirmationWaitSeconds,
        pollMilliseconds: Int = confirmationPollMilliseconds,
        onConfirmationRequired: (@MainActor () -> Void)? = nil
    ) async -> RealtimeToolDispatch {
        let startedUptime = ProcessInfo.processInfo.systemUptime
        var firstRequestSentUptime: TimeInterval?
        func finished(_ result: [String: Any], waited: Bool, harnessResponse: [String: Any]?) -> RealtimeToolDispatch {
            RealtimeToolDispatch(
                result: result,
                harnessMilliseconds: Int(((ProcessInfo.processInfo.systemUptime - startedUptime) * 1000).rounded()),
                waitedForConfirmation: waited,
                harnessResponse: harnessResponse,
                firstRequestSentUptime: firstRequestSentUptime,
                answeredUptime: ProcessInfo.processInfo.systemUptime
            )
        }
        var firstLine: String
        switch harnessRequestLine(for: call) {
        case .success(let line): firstLine = line
        case .failure(let refusal): return finished(toolResult(for: refusal), waited: false, harnessResponse: nil)
        }
        // Menu verbs act only in the app the tool named, resolved to one bundle.
        var named: (bundleIdentifier: String, name: String)?
        if RealtimeVoiceVerbs.isAppScopedMenuTool(call.name), let appName = call.appName {
            let identity = await Task.detached { RealtimeVoiceVerbs.appIdentity(named: appName) }.value
            guard case .resolved(let bundleIdentifier, let name) = identity,
                  case .success(let line) = harnessRequestLine(for: call, expectApp: bundleIdentifier) else {
                var dispatch = finished(appCheckRefusal(identity, named: appName), waited: false, harnessResponse: nil)
                dispatch.appCheck = appCheck(identity, named: appName, harnessResponse: nil)
                return dispatch
            }
            named = (bundleIdentifier, name)
            firstLine = line
        }
        func checked(_ dispatch: RealtimeToolDispatch) -> RealtimeToolDispatch {
            guard let named, let appName = call.appName else { return dispatch }
            var dispatch = dispatch
            dispatch.appCheck = appCheck(.resolved(bundleIdentifier: named.bundleIdentifier, name: named.name),
                                         named: appName, harnessResponse: dispatch.harnessResponse)
            if dispatch.result["error"] as? String == "frontmostChanged" {
                let frontmost = ((dispatch.harnessResponse?["actualApp"] as? [String: Any])?["name"] as? String) ?? "another app"
                dispatch.result["error"] = "appMismatch"
                dispatch.result["named"] = named.name
                dispatch.result["frontmost"] = String(frontmost.prefix(60))
                dispatch.result["message"] = "\(named.name) is not the app in front; \(UntrustedText(frontmost).forDisplay) is. "
                    + "Nothing was searched or pressed. Focus \(named.name) first, or ask the owner which app they meant."
            }
            return dispatch
        }

        let (firstRequestUptime, firstAnswer) = await Task.detached { (ProcessInfo.processInfo.systemUptime, answer(firstLine)) }.value
        firstRequestSentUptime = firstRequestUptime
        var response = harnessResponseObject(firstAnswer)
        // A read: only privacy-filtered candidates reach the model.
        if call.name == RealtimeVoiceVerbs.findMenuItemsName {
            var result = toolResult(fromHarnessResponse: response)
            var offer: RealtimeMenuOffer?
            if response["ok"] as? Bool == true {
                let madeOffer = RealtimeVoiceVerbs.menuOffer(fromMenusResponse: response, words: call.words ?? "")
                result["candidates"] = madeOffer.candidates.map(\.jsonObject)
                if madeOffer.listingIncomplete { result["listingIncomplete"] = true }
                offer = madeOffer
            }
            response["items"] = nil
            var dispatch = finished(result, waited: false, harnessResponse: response)
            dispatch.menuOffer = offer
            return checked(dispatch)
        }
        guard response["error"] as? String == "confirmationRequired", let ticket = response["ticket"] as? String,
              case .success(let ticketLine) = harnessRequestLine(for: call, ticket: ticket, expectApp: named?.bundleIdentifier) else {
            return checked(finished(toolResult(fromHarnessResponse: response), waited: false, harnessResponse: response))
        }
        await onConfirmationRequired?()
        let deadline = startedUptime + confirmationWaitSeconds
        repeat {
            try? await Task.sleep(for: .milliseconds(pollMilliseconds))
            response = harnessResponseObject(await Task.detached { answer(ticketLine) }.value)
        } while response["error"] as? String == "confirmationPending" && ProcessInfo.processInfo.systemUptime < deadline
        return checked(finished(toolResult(fromHarnessResponse: response), waited: true, harnessResponse: response))
    }

    /// What the model is told when the named app isn't exactly one installed app.
    static func appCheckRefusal(_ identity: RealtimeVoiceVerbs.AppIdentity, named appName: String) -> [String: Any] {
        let shown = UntrustedText(appName).forDisplay
        switch identity {
        case .ambiguous(let candidates):
            return ["ok": false, "status": NSNull(), "error": "ambiguousApp", "named": appName, "candidates": candidates,
                    "message": "more than one installed app answers to \(shown): \(candidates.joined(separator: ", ")). "
                        + "Nothing was searched or pressed; ask the owner which one they meant."]
        case .notInstalled(let closest):
            return ["ok": false, "status": NSNull(), "error": "appNotInstalled", "named": appName, "candidates": closest,
                    "message": "no installed app is called \(shown). Nothing was searched or pressed"
                        + (closest.isEmpty ? "." : "; apps sharing a word with it: \(closest.joined(separator: ", ")).")]
        case .resolved:
            return ["ok": false, "status": NSNull(), "error": "requestEncodingFailed", "message": "the request could not be encoded"]
        }
    }

    /// What the named app resolved to, and what the harness found in front.
    static func appCheck(_ identity: RealtimeVoiceVerbs.AppIdentity, named appName: String,
                         harnessResponse: [String: Any]?) -> [String: Any] {
        var check: [String: Any] = ["named": appName, "resolvedBundleId": NSNull(), "frontmostBundleId": NSNull()]
        switch identity {
        case .ambiguous: check["outcome"] = "ambiguousApp"
        case .notInstalled: check["outcome"] = "appNotInstalled"
        case .resolved(let bundleIdentifier, _):
            check["resolvedBundleId"] = bundleIdentifier
            if harnessResponse?["error"] as? String == "frontmostChanged" {
                check["outcome"] = "appMismatch"
                check["frontmostBundleId"] = (harnessResponse?["actualApp"] as? [String: Any])?["bundleIdentifier"] ?? NSNull()
            } else if let frontmost = harnessResponse?["bundleIdentifier"] as? String {
                check["outcome"] = "match"
                check["frontmostBundleId"] = frontmost
            } else {
                check["outcome"] = "notChecked"
            }
        }
        return check
    }

    // MARK: Fresh look

    /// Long edge of the fresh window view sent to the model.
    static let freshLookMaxPixelDimension = 1024
    static let freshLookJPEGQuality = 0.7

    /// The harness's `look`, pinned to the app just launched.
    static func lookRequestLine(expectApp bundleIdentifier: String) -> String? {
        let request: [String: Any] = ["verb": "look", "tier": "window", "expectApp": bundleIdentifier]
        return (try? JSONSerialization.data(withJSONObject: request, options: [.sortedKeys])).map { String(decoding: $0, as: UTF8.self) }
    }

    /// Only after `ok: true`. `answer` blocks, so this runs detached.
    static func freshLook(afterLaunchResponse launchResponse: [String: Any]?,
                          answer: @escaping @Sendable (String) -> String) async -> RealtimeFreshLook {
        guard let bundleIdentifier = launchResponse?["bundleIdentifier"] as? String,
              let line = lookRequestLine(expectApp: bundleIdentifier) else { return .unavailable(error: "noBundleIdentifier") }
        let response = harnessResponseObject(await Task.detached { answer(line) }.value)
        return freshLook(fromLookResponse: response) { path in try? Data(contentsOf: URL(fileURLWithPath: path)) }
    }

    static func freshLook(fromLookResponse response: [String: Any], readImage: (String) -> Data?) -> RealtimeFreshLook {
        guard !response.isEmpty else { return .unavailable(error: "unreadableHarnessResponse") }
        guard response["ok"] as? Bool == true else { return .unavailable(error: response["error"] as? String ?? "lookFailed") }
        guard let path = response["imagePath"] as? String, let imageData = readImage(path) else { return .unavailable(error: "imageUnreadable") }
        guard let jpeg = downscaledJPEG(imageData, maxPixelDimension: freshLookMaxPixelDimension) else { return .unavailable(error: "imageDownscaleFailed") }
        return .image(jpeg)
    }

    static func downscaledJPEG(_ imageData: Data, maxPixelDimension: Int) -> Data? {
        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelDimension,
                kCGImageSourceCreateThumbnailWithTransform: true
              ] as CFDictionary) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: freshLookJPEGQuality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    // MARK: Notch

    /// A name for the notch, escaped when needed so it can't forge a second line.
    static func captionName(_ raw: String) -> String {
        let shown = UntrustedText(raw).forDisplay
        return shown == "\"\(raw)\"" ? raw : shown
    }

    /// The notch's answer, from the harness's own fields. nil for a successful
    /// find: a read proves nothing happened.
    static func notchAnswer(for call: RealtimeToolCall, dispatch: RealtimeToolDispatch) -> GoNotchEvent? {
        let error = dispatch.result["error"] as? String
        switch call.name {
        case RealtimeVoiceVerbs.findMenuItemsName:
            return dispatch.harnessConfirmed ? nil : .harnessAnswered(ok: false, subject: "", error: error)
        case RealtimeVoiceVerbs.pressMenuName:
            return .harnessAnswered(ok: dispatch.harnessConfirmed,
                                    subject: RealtimeVoiceVerbs.menuPathCaption(call.path ?? []), error: error)
        default:
            let name = (dispatch.harnessResponse?["application"] as? String) ?? call.appName ?? "The app"
            return .harnessAnswered(ok: dispatch.harnessConfirmed, subject: captionName(name), error: error)
        }
    }
}

nonisolated enum RealtimeFreshLook {
    case image(Data)
    case unavailable(error: String)

    var outcome: String {
        switch self {
        case .image: return "attached"
        case .unavailable(let error): return error
        }
    }
}

nonisolated struct RealtimeToolRefusal: Error, Equatable {
    let error: String
    let message: String
}

nonisolated struct RealtimeToolDispatch {
    var result: [String: Any]
    let harnessMilliseconds: Int
    let waitedForConfirmation: Bool
    /// nil when the harness was never asked.
    let harnessResponse: [String: Any]?
    var firstRequestSentUptime: TimeInterval? = nil
    var answeredUptime: TimeInterval? = nil
    /// find_menu_items only: what the model was offered.
    var menuOffer: RealtimeMenuOffer? = nil
    var appCheck: [String: Any]? = nil
    var heardCheck: [String: Any]? = nil
    /// A menu tool that came back `appMismatch`: whether Go focused the app and re-ran.
    var autoFocus: [String: Any]? = nil

    var harnessConfirmed: Bool { result["ok"] as? Bool == true }
}
