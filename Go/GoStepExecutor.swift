import AppKit

/// Performs one planned walkthrough step through Go's accessibility harness,
/// so the safety kernel, owner confirmations and post-action verification all
/// apply exactly as they do for any other Go action.
nonisolated enum GoStepExecutor {
    enum Outcome: Equatable, Sendable {
        /// The harness acted and did not report a failed verification.
        case done
        /// Worth another attempt from a fresh reading of the screen.
        case retryable(String)
        /// Safety refusal, owner declined, or nothing Go can act on: stop.
        case blocked(String)
    }

    /// Types into whatever has focus and/or presses a key combination, in the
    /// step's app only, never into a password field or during secure input.
    private static func performKeyboard(_ step: GoWalkthroughStep) async -> Outcome {
        let app = step.app
        if let text = step.typeText {
            if let refusal = GoKeystrokes.keyboardRefusal(for: text, app: app) { return .blocked(refusal) }
            // Typing goes in at the cursor: when the field already holds the start of
            // the text (the owner began it) only the rest is typed, and nothing when
            // it's all there, so the text is never doubled.
            let rest = await Task.detached(operation: { GoTextFields.remainder(of: text, after: GoTextFields.focusedContents(app: app)) }).value
            if !rest.isEmpty {
                guard await Task.detached(operation: { GoKeystrokes.type(rest, app: app) }).value else {
                    return .retryable("I couldn't type there")
                }
            }
        }
        if let keys = step.keys {
            guard let combo = GoKeyCombo.parse(keys) else { return .blocked("I don't know those keys") }
            if let refusal = combo.refusal { return .blocked(refusal) }
            if step.typeText != nil { try? await Task.sleep(for: .milliseconds(120)) }
            guard await Task.detached(operation: { GoKeystrokes.press(combo, app: app) }).value else {
                return .retryable("I couldn't press those keys there")
            }
        }
        return .done
    }

    /// The harness request for a step, or nil when Go has no safe way to act on it.
    static func requestLine(for step: GoWalkthroughStep) -> String? {
        var request: [String: Any] = ["expectApp": step.app]
        if let app = step.launchApp {
            // Launch is not about the app in front, so it carries no expectation.
            request = ["verb": "launch", "app": app]
        } else if let menu = step.menu {
            request["verb"] = "menu"; request["path"] = menu.path
        } else if let control = step.control {
            // Opening (a file or folder) always asks the owner in the safety kernel.
            // Rows, cells and labels are chosen by selection; everything else is pressed.
            request["verb"] = step.opens ? "open" : ["AXRow", "AXCell", "AXStaticText"].contains(control.role) ? "select" : "press"
            request["title"] = control.name; request["role"] = control.role
        } else if let field = step.field, let text = step.typeText {
            request["verb"] = "type"; request["text"] = text; request["mode"] = "replace"
            if field.focused { request["target"] = "focused" }
            else if !field.label.isEmpty { request["title"] = field.label; request["role"] = field.role }
            else { return nil }
        } else {
            return nil
        }
        guard let data = try? JSONSerialization.data(withJSONObject: request) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    static func perform(_ step: GoWalkthroughStep, answer: @escaping @Sendable (String) -> String,
                        onConfirmationRequired: @escaping @MainActor () -> Void) async -> Outcome {
        // The planner's judgement of the step's real effect sits on top of the
        // fixed checks below. It can only stop Go, never let through what they block.
        if let refusal = riskRefusal(step.risk) { return .blocked(refusal) }
        if step.reveal {
            guard let direction = step.scrollDirection else { return .retryable("I can't reveal that part myself") }
            let app = step.app
            return await Task.detached(operation: { GoScreenClick.scroll(direction, inFrontWindowOf: app) }).value
                ? .done : .retryable("I couldn't scroll there")
        }
        if step.keyboard { return await performKeyboard(step) }
        if let rect = step.screenRect?.rect { return await performOnScreen(step, at: rect, answer: answer) }
        var step = step
        // An app named in words becomes the one installed bundle it resolves to.
        if let name = step.launchApp {
            guard case .resolved(let bundleIdentifier, _) = await Task.detached(operation: { RealtimeVoiceVerbs.appIdentity(named: name) }).value
            else { return .blocked("I couldn't find one installed app called \(UntrustedText(name).forDisplay)") }
            step.launchApp = bundleIdentifier
        }
        guard let line = requestLine(for: step) else { return .blocked("I can't act on that control myself") }
        // Apps whose buttons ignored an Accessibility press earlier (many web apps
        // listen only for real pointer events): ask the kernel first, then click.
        if step.control != nil, !step.opens, await GoPointerApps.contains(step.app),
           let dryRun = withField(line, "dryRun", true) {
            let verdict = RealtimeOpenAppTool.harnessResponseObject(await Task.detached { answer(dryRun) }.value)
            if verdict["ok"] as? Bool == true, let outcome = await pointerClick(step, answer: answer) { return outcome }
        }
        var response = RealtimeOpenAppTool.harnessResponseObject(await Task.detached { answer(line) }.value)
        // Owner confirmation: the existing panel asks; Go waits for the answer.
        if response["error"] as? String == "confirmationRequired", let ticket = response["ticket"] as? String,
           var object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] {
            object["ticket"] = ticket
            let ticketLine = String(decoding: (try? JSONSerialization.data(withJSONObject: object)) ?? Data(), as: UTF8.self)
            await onConfirmationRequired()
            let deadline = ProcessInfo.processInfo.systemUptime + RealtimeOpenAppTool.confirmationWaitSeconds
            repeat {
                try? await Task.sleep(for: .milliseconds(RealtimeOpenAppTool.confirmationPollMilliseconds))
                response = RealtimeOpenAppTool.harnessResponseObject(await Task.detached { answer(ticketLine) }.value)
            } while response["error"] as? String == "confirmationPending" && ProcessInfo.processInfo.systemUptime < deadline
        }
        // The kernel refused only because the field takes keystrokes, not a value
        // write (Terminal and similar). Type real keys, after command screening.
        if let text = step.typeText, response["error"] as? String == "kernelRefused",
           ((response["kernel"] as? [String: Any])?["reason"] as? String)?.hasPrefix("element does not publish a settable") == true {
            if let refusal = GoKeystrokes.refusal(for: text) { return .blocked(refusal) }
            let app = step.app
            guard await Task.detached(operation: { GoKeystrokes.type(text, app: app) }).value else {
                return .retryable("I couldn't type into that window")
            }
            if step.pressReturn {
                try? await Task.sleep(for: .milliseconds(150))
                _ = await Task.detached(operation: { GoTextFields.pressReturn(app: app) }).value
            }
            return .done
        }
        // The kernel allowed the action, but the app refused it (performFailed: many
        // grids, canvases and web views don't take Accessibility actions) or didn't
        // react (notVerified): the same target, clicked with the pointer, is the
        // same action, the way a person would do it.
        if ["notVerified", "performFailed"].contains(response["error"] as? String ?? ""), step.control != nil, !step.opens,
           let outcome = await pointerClick(step, answer: answer) {
            await GoPointerApps.insert(step.app)
            return outcome
        }
        let result = outcome(from: response)
        // Renames and searches only take effect on Return; the planner never marks send or pay steps.
        if result == .done, step.typeText != nil, step.pressReturn {
            try? await Task.sleep(for: .milliseconds(150))
            let app = step.app
            guard await Task.detached(operation: { GoTextFields.pressReturn(app: app) }).value else {
                return .retryable("I couldn't confirm the text with Return")
            }
        }
        return result
    }

    /// Screening for a target known only from the screenshot, using the safety
    /// kernel's own word lists: irreversible actions are refused, destructive ones
    /// are left to the owner (there is no element to ask a confirmation about).
    static func screenTargetRefusal(label: String, instruction: String, elementNames: [String]) -> String? {
        let text = ([label, instruction] + elementNames).joined(separator: " ").lowercased()
        if ActionSafetyKernel.irreversibleTitleKeywords.contains(where: { text.contains($0) }) {
            return "that can't be undone, so it's one for you to do"
        }
        if ActionSafetyKernel.destructiveTitleKeywords.contains(where: { text.contains($0) }) {
            return "that looks like it deletes or sends something, so please do it yourself"
        }
        return nil
    }

    /// Clicks (or double-clicks, to open) the centre of a screenshot-located
    /// target, leaving the pointer there. Typing steps click to focus,
    /// then type through the harness into the focused field.
    private static func performOnScreen(_ step: GoWalkthroughStep, at rect: CGRect,
                                        answer: @escaping @Sendable (String) -> String) async -> Outcome {
        let point = CGPoint(x: rect.midX, y: rect.midY)
        let element = GoScreenClick.describeElement(at: point)
        if element.isSecure { return .blocked("that's a password field") }
        if let refusal = screenTargetRefusal(label: step.screenLabel ?? "", instruction: step.instruction, elementNames: element.names) {
            return .blocked(refusal)
        }
        guard GoScreenClick.click(at: point, count: step.opens ? 2 : 1, restoringPointer: false) else { return .retryable("I couldn't click there") }
        if let wrongApp = await leftTheApp(step) { return wrongApp }
        guard let text = step.typeText else { return .done }
        try? await Task.sleep(for: .milliseconds(250))
        let typed = GoWalkthroughStep(instruction: step.instruction, app: GoActiveApp.bundleIdentifier ?? step.app,
                                      windowToken: step.windowToken, control: nil, menu: nil, expected: nil,
                                      field: GoTextField(id: "focused", role: "AXTextField", label: "", focused: true,
                                                         x: rect.minX, y: rect.minY, w: rect.width, h: rect.height),
                                      typeText: text, pressReturn: step.pressReturn)
        return await perform(typed, answer: answer, onConfirmationRequired: {})
    }

    /// A real click on the step's control, located by the same grounding used for pointing.
    private static func pointerClick(_ step: GoWalkthroughStep, answer: @escaping @Sendable (String) -> String) async -> Outcome? {
        guard let rect = await GoGuidePresenter.resolve(step, answer: answer) else { return nil }
        let point = CGPoint(x: rect.midX, y: rect.midY)
        if GoScreenClick.describeElement(at: point).isSecure { return .blocked("that's a password field") }
        guard GoScreenClick.click(at: point, count: 1, restoringPointer: false) else { return nil }
        return await leftTheApp(step) ?? .done
    }

    /// A click meant for the step's own app that brought another app to the front
    /// hit the wrong thing (a Dock icon beside a sheet tab, a notification). Put
    /// the app back and report it, so Go re-plans instead of carrying on elsewhere.
    /// Steps that are meant to leave the app (Dock and menu-bar items, opening a
    /// file) are not checked.
    private static func leftTheApp(_ step: GoWalkthroughStep) async -> Outcome? {
        guard !step.outsideWindow, !step.opens else { return nil }
        try? await Task.sleep(for: .milliseconds(250))
        guard !GoActiveApp.isActive(step.app) else { return nil }
        NSRunningApplication.runningApplications(withBundleIdentifier: step.app).first?.activate()
        try? await Task.sleep(for: .milliseconds(300))
        return .retryable("that click brought a different app to the front")
    }

    private static func withField(_ line: String, _ key: String, _ value: Any) -> String? {
        guard var object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { return nil }
        object[key] = value
        return (try? JSONSerialization.data(withJSONObject: object)).map { String(decoding: $0, as: UTF8.self) }
    }

    static func riskRefusal(_ risk: GoRisk?) -> String? {
        guard let risk, risk.level != .none else { return nil }
        let why = risk.reason.flatMap { UntrustedText($0).isPlausibleControlLabel ? $0 : nil }
        switch risk.level {
        case .none: return nil
        case .secret: return "that needs a password or other secret, so it's yours to enter"
        case .irreversible: return "that can't be undone" + (why.map { " (\($0))" } ?? "") + ", so it's one for you to do"
        // "confirm" is asked by the coordinator before Go gets here; approved steps pass.
        case .confirm: return nil
        }
    }

    static func outcome(from response: [String: Any]) -> Outcome {
        if response["ok"] as? Bool == true { return .done }
        let error = response["error"] as? String ?? "unknown"
        // Safety and consent refusals are final: never retried around.
        if ["kernelRefused", "killSwitch", "guidanceOnly", "tooManyPendingConfirmations"].contains(error)
            || error.hasPrefix("confirmation") {
            return .blocked(reason(for: error))
        }
        return .retryable(reason(for: error))
    }

    private static func reason(for error: String) -> String {
        switch error {
        case "kernelRefused": return "my safety check won't let me do that one"
        case "killSwitch": return "actions are switched off"
        case let code where code.hasPrefix("confirmation") || code == "tooManyPendingConfirmations":
            return "it needed your OK and didn't get it"
        case "notFound": return "I couldn't find that control"
        case "ambiguous": return "more than one control matched"
        case "notVerified": return "nothing seemed to change"
        case "frontmostChanged", "appMismatch": return "a different app came to the front"
        case "targetNotOnScreen": return "that control is off screen"
        default: return "it didn't work"
        }
    }
}
