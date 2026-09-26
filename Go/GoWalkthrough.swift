import CoreGraphics
import Foundation

nonisolated struct GoControl: Codable, Equatable, Sendable {
    let id: String
    let role: String
    let name: String
    let radioSelection: Bool?
}

/// A rectangle in global AppKit coordinates.
nonisolated struct GoFrame: Codable, Equatable, Sendable {
    let x: Double, y: Double, w: Double, h: Double
    var rect: CGRect { CGRect(x: x, y: y, width: w, height: h) }
    init(_ rect: CGRect) { x = rect.minX; y = rect.minY; w = rect.width; h = rect.height }
}

nonisolated struct GoMenuTarget: Codable, Equatable, Sendable {
    let id: String
    let path: [String]
}

/// Only labelled controls go to the planner. No text field contents or images.
nonisolated struct GoObservation: Codable, Equatable, Sendable {
    let app: String
    let windowToken: String
    let windowName: String
    let complete: Bool
    let controls: [GoControl]
    var menus: [GoMenuTarget] = []
    /// Typeable fields by label only (GoTextFields); filled when planning.
    var fields: [GoTextField] = []
    /// The display the planning screenshot shows, so a box on it maps to the screen.
    var screenFrame: GoFrame? = nil
    /// The observed window's frame, so fixed-position targets can follow a window move.
    var windowFrame: GoFrame? = nil
    /// Controls outside the app: menu-bar status icons and Dock items.
    var systemControls: [GoSystemControl] = []

    /// The listed outside-the-app control a screenshot box means, so the step
    /// uses its exact frame. A control named in the planner's label wins among
    /// those near the box (a box can be one icon off); otherwise the one under
    /// the box's centre. Nil when neither identifies exactly one.
    func systemControl(near rect: CGRect, label: String?) -> GoSystemControl? {
        if case .snap(let control) = systemControlMatch(near: rect, label: label) { return control }
        return nil
    }

    enum SystemControlMatch: Equatable {
        /// The box means this Dock item or menu-bar icon.
        case snap(GoSystemControl)
        /// The box sits on this item, but the label describes something else:
        /// the box is off target (often an app's bottom or top edge beside the Dock
        /// or menu bar), and clicking it would act on another app.
        case offTarget(GoSystemControl)
        case none
    }

    func systemControlMatch(near rect: CGRect, label: String?) -> SystemControlMatch {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let nearby = systemControls.filter { control in
            let frame = control.frame.rect
            return frame.insetBy(dx: -max(rect.width, 40), dy: -max(rect.height, 24)).contains(center)
        }
        let labelWords = Self.distinctiveWords(label ?? "")
        if let label = label?.lowercased(), !label.isEmpty {
            let named = nearby.filter { label.contains($0.name.lowercased()) || !labelWords.isDisjoint(with: Self.distinctiveWords($0.name)) }
            if named.count == 1 { return .snap(named[0]) }
        }
        let under = nearby.filter { $0.frame.rect.contains(center) }
        guard under.count == 1 else { return .none }
        // A label with nothing specific in it ("the icon") takes the item under the box.
        return labelWords.isEmpty ? .snap(under[0]) : .offTarget(under[0])
    }

    /// The words of a label that could name something: not "the", "icon", "button"…
    static func distinctiveWords(_ text: String) -> Set<String> {
        let generic: Set<String> = ["the", "and", "for", "with", "icon", "button", "item", "menu", "bar", "dock", "control",
                                    "top", "bottom", "left", "right", "corner", "symbol", "logo", "app", "status", "extra",
                                    "click", "open", "press", "tap", "select", "choose", "this", "that", "here", "there"]
        let words = text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        return Set(words.filter { $0.count >= 3 && !generic.contains($0) })
    }

    /// The controls the planner is shown when there are too many to send them
    /// all. Content (spreadsheet cells, table rows, file names, labels, images)
    /// can run to thousands and would otherwise push the app's own commands
    /// (buttons, tabs, menus, sheet tabs listed after a grid) out of the list,
    /// leaving only screenshot guesses for them. Commands are kept first, with
    /// room reserved for content; both keep their on-screen order.
    static func catalogControls(_ controls: [GoControl], limit: Int = 200, contentShare: Int = 50) -> [GoControl] {
        guard controls.count > limit else { return controls }
        let contentRoles: Set<String> = ["AXCell", "AXRow", "AXStaticText", "AXImage", "AXTextField"]
        let indexed = Array(controls.enumerated())
        let commands = indexed.filter { !contentRoles.contains($0.element.role) }
        let content = indexed.filter { contentRoles.contains($0.element.role) }
        let contentSlots = min(content.count, max(contentShare, limit - commands.count))
        let commandSlots = min(commands.count, limit - contentSlots)
        let kept = commands.prefix(commandSlots) + content.prefix(limit - commandSlots)
        return kept.sorted { $0.offset < $1.offset }.map(\.element)
    }

    /// A planner box [ymin, xmin, ymax, xmax] on 0–1000 over the screenshot,
    /// as a screen rectangle. Nil for anything malformed, tiny or implausibly large.
    func screenRect(forBox box: [Double]?) -> CGRect? {
        guard let box, box.count == 4, box.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 1000 }),
              box[0] < box[2], box[1] < box[3], let screen = screenFrame?.rect else { return nil }
        let rect = CGRect(x: screen.minX + box[1] / 1000 * screen.width,
                          y: screen.maxY - box[2] / 1000 * screen.height,
                          width: (box[3] - box[1]) / 1000 * screen.width,
                          height: (box[2] - box[0]) / 1000 * screen.height)
        guard rect.width >= 4, rect.height >= 4,
              rect.width <= screen.width * 0.6, rect.height <= screen.height * 0.6 else { return nil }
        return rect
    }

    static func decode(_ object: [String: Any]) -> GoObservation? {
        guard object["ok"] as? Bool == true,
              let app = object["bundleIdentifier"] as? String, !app.isEmpty,
              let window = object["window"] as? [String: Any],
              let token = window["token"] as? String, !token.isEmpty,
              let elements = object["elements"] as? [[String: Any]] else { return nil }
        let allowedRoles: Set<String> = ["AXButton", "AXRadioButton", "AXCheckBox", "AXPopUpButton",
            "AXMenuButton", "AXLink", "AXTab", "AXCell", "AXRow", "AXDisclosureTriangle", "AXMenuItem",
            // Visible items people ask about: sidebar labels, icons, and files/folders.
            "AXStaticText", "AXImage", "AXTextField"]
        let controls = elements.enumerated().compactMap { index, element -> GoControl? in
            guard element["nameIsPlausibleLabel"] as? Bool == true,
                  let role = element["role"] as? String, allowedRoles.contains(role),
                  let name = element["name"] as? String, !name.isEmpty, name.count <= 160 else { return nil }
            let actions = element["actions"] as? [String] ?? []
            // A text field's name can be what someone typed; only items that open
            // (files and folders in a list) are listed, never editable fields.
            if role == "AXTextField", !actions.contains("AXOpen") { return nil }
            // Labels are short; long static text is document content, not a place to point.
            if role == "AXStaticText", name.count > 60 { return nil }
            return GoControl(id: "c\(index)", role: role, name: name, radioSelection: element["radioSelection"] as? Bool)
        }
        var windowFrame: GoFrame?
        if let frame = window["frame"] as? [String: Any], let x = frame["x"] as? Double, let y = frame["y"] as? Double,
           let w = frame["w"] as? Double, let h = frame["h"] as? Double { windowFrame = GoFrame(CGRect(x: x, y: y, width: w, height: h)) }
        var observation = GoObservation(app: app, windowToken: token, windowName: window["name"] as? String ?? "",
                             complete: (object["walkStopReasons"] as? [String]) == [] &&
                                object["focusChangedDuringWalk"] as? Bool == false && object["incompleteReads"] as? Bool == false,
                             controls: controls)
        observation.windowFrame = windowFrame
        return observation
    }

    /// Changes when the window or its listed controls change.
    var contextHash: Int {
        var hasher = Hasher()
        hasher.combine(app); hasher.combine(windowToken); hasher.combine(windowName)
        for control in controls { hasher.combine(control.role); hasher.combine(control.name); hasher.combine(control.radioSelection) }
        return hasher.finalize()
    }

    func matches(role: String, name: String) -> [GoControl] {
        controls.filter { $0.role == role && $0.name == name }
    }
}

nonisolated struct GoExpectedState: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case elementAppeared, elementDisappeared, radioSelected, windowAppeared }
    let kind: Kind
    let role: String
    let name: String

    func isSatisfied(in observation: GoObservation) -> Bool {
        guard observation.complete else { return false }
        let matches = observation.matches(role: role, name: name)
        switch kind {
        case .elementAppeared: return matches.count == 1
        case .elementDisappeared: return matches.isEmpty
        case .radioSelected: return matches.count == 1 && matches.first?.radioSelection == true
        case .windowAppeared: return !name.isEmpty && observation.windowName == name
        }
    }

    func canObserveChange(from observation: GoObservation) -> Bool {
        guard observation.complete, !name.isEmpty, name.count <= 160 else { return false }
        let matches = observation.matches(role: role, name: name)
        switch kind {
        case .elementAppeared: return matches.isEmpty
        case .elementDisappeared: return matches.count == 1
        case .radioSelected: return role == "AXRadioButton" && matches.count == 1 && matches.first?.radioSelection == false
        case .windowAppeared: return observation.windowName != name
        }
    }
}

nonisolated struct GoStepProposal: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case step, ask, done, answer, point, launch, reveal }
    let kind: Kind
    let instruction: String
    var targetID: String?
    let expected: GoExpectedState?
    /// For a typing step: exactly what the owner should type.
    var typeText: String? = nil
    /// The typed text takes effect only after Return (never for sending or paying).
    var pressReturn: Bool? = nil
    /// The step opens the target (double-click a file or folder).
    var open: Bool? = nil
    /// For a launch step: the application to open.
    var app: String? = nil
    /// For a control found only in the screenshot: its box and a short description.
    var box: [Double]? = nil
    var label: String? = nil
    /// The lists were not enough and no screenshot was attached: plan again with one.
    var needScreen: Bool? = nil
    /// The planner's judgement of what this step would do; it can only add caution.
    var risk: GoRisk? = nil
    /// For a reveal step: "down" or "up" when the owner should scroll.
    var scroll: String? = nil
    /// For a keyboard step (targetID "keyboard"): a key or shortcut such as
    /// "return", "tab" or "cmd+d", pressed after any `typeText`.
    var keys: String? = nil
}

nonisolated struct GoRisk: Codable, Equatable, Sendable {
    /// none: ordinary or easy to undo; confirm: Go asks the owner first;
    /// irreversible and secret: never performed by Go.
    enum Level: String, Codable, Sendable { case none, confirm, irreversible, secret }
    let level: Level
    let reason: String?
}

nonisolated struct GoWalkthroughStep: Codable, Equatable, Sendable {
    let instruction: String
    let app: String
    let windowToken: String
    let control: GoControl?
    let menu: GoMenuTarget?
    /// Nil for typing steps, which complete when the field holds `typeText`.
    let expected: GoExpectedState?
    var field: GoTextField? = nil
    var typeText: String? = nil
    /// A "where is it" highlight: finished by the owner's click, with no next step.
    var final = false
    var pressReturn = false
    /// Opens the target; done when a new window or app appears, not on the first click.
    var opens = false
    /// Launch step: done when this application comes to the front.
    var launchApp: String? = nil
    /// The window's title when the step was planned; opening a folder changes it.
    var windowName = ""
    /// A target seen only in the screenshot (icon-only, custom-drawn, Dock, menu bar extras).
    var screenRect: GoFrame? = nil
    var screenLabel: String? = nil
    /// The screen target is outside the app's window (a menu-bar icon or Dock
    /// item), so it stays put when the window moves.
    var outsideWindow = false
    /// The listed menu-bar icon or Dock item this step targets, by name.
    var outsideName: String? = nil
    /// A keyboard step: type `typeText` into whatever has focus (a selected
    /// cell, a canvas, a terminal) and/or press `keys`.
    var keys: String? = nil
    var keyboard = false
    /// The screen's `contextHash` when this step was planned.
    var contextHash = 0
    /// The window's frame when this step was planned (see `GoObservation.windowFrame`).
    var windowFrame: GoFrame? = nil
    /// A reveal step (scroll, expand, hover): done once the owner has acted and paused.
    var reveal = false
    var scrollDirection: String? = nil
    var risk: GoRisk? = nil

    /// A short description of the step for Go's own short-term memory, with
    /// what was typed (unless the field looks like it holds a secret), so
    /// "undo that" or "do the same again" can refer to it.
    var targetDescription: String {
        if keyboard {
            let pressing = keys.flatMap(GoKeyCombo.parse).map { "pressing " + $0.display }
            let typing = typeText.map { "typing \u{201C}\($0)\u{201D}" }
            return [typing, pressing].compactMap { $0 }.joined(separator: " then ")
        }
        guard let typeText, !GoRoutineStep.isSecretLabel(field?.label ?? screenLabel ?? "") else { return targetName }
        return "typing \u{201C}\(typeText)\u{201D} into " + targetName
    }

    private var targetName: String {
        if reveal { return "scrolling to " + (screenLabel ?? "the next part") }
        if let screenLabel { return screenLabel }
        if let launchApp { return "the app \(launchApp)" }
        if let menu { return "menu item " + menu.path.joined(separator: " > ") }
        if let field { return field.label.isEmpty ? "a text field" : "the \(field.label) field" }
        if let control { return "\(control.role.replacingOccurrences(of: "AX", with: "").lowercased()) '\(control.name)'" }
        return "a control"
    }

    /// For logs: what kind of target the step has, never its name.
    var kindLabel: String {
        keyboard ? "keyboard" : reveal ? "reveal" : screenRect != nil ? "screen" : launchApp != nil ? "launch" : menu != nil ? "menu" : field != nil ? "field" : opens ? "open" : "control"
    }

    /// Identifies what the step acts on, so an action that changed nothing is noticed.
    var signature: String {
        if keyboard { return "keyboard:\(keys ?? ""):\(typeText ?? "")" }
        if reveal { return "reveal:\(scrollDirection ?? ""):\(screenLabel ?? instruction)" }
        if let screenRect { return "screen:\(Int(screenRect.x / 20)),\(Int(screenRect.y / 20))" }
        if let launchApp { return "launch:\(launchApp)" }
        if let menu { return "menu:" + menu.path.joined(separator: ">") }
        if let field { return "field:\(field.role):\(field.label):\(typeText ?? "")" }
        return "control:\(control?.role ?? ""):\(control?.name ?? "")"
    }
}

/// One proposed step at a time. App names and task sequences are never rules.
nonisolated struct GoWalkthroughState: Sendable {
    enum Phase: String, Sendable { case idle, planning, waiting, needsInput, done, stopped }
    private(set) var phase: Phase = .idle
    private(set) var step: GoWalkthroughStep?
    private(set) var verifiedSteps: [GoWalkthroughStep] = []
    private(set) var message = ""
    private(set) var app: String?
    private var firstMatchAt: TimeInterval?
    private var offTrackAt: TimeInterval?
    /// One redirect per departure; reset once the owner is back on the step.
    private var offTrackReported = false
    /// Set when the last proposal's screenshot box fell on a Dock item or
    /// menu-bar icon its label doesn't name; the coordinator plans again.
    private(set) var boxLandedOn: GoSystemControl?

    mutating func planning() { phase = .planning; step = nil; firstMatchAt = nil; offTrackAt = nil; offTrackReported = false }

    /// Back to a step that is still valid, e.g. after the owner wandered off and
    /// planning from the new screen failed. Better than giving up.
    mutating func restore(_ previous: GoWalkthroughStep, message text: String) {
        phase = .waiting; step = previous; message = text
        firstMatchAt = nil; offTrackAt = nil; offTrackReported = false
    }

    /// Records a finished step; a final (point) step ends the walkthrough quietly.
    private mutating func advance(_ finished: GoWalkthroughStep) {
        verifiedSteps.append(finished)
        if finished.final { phase = .done; step = nil; message = ""; firstMatchAt = nil; offTrackAt = nil }
        else { planning() }
    }
    /// Replaces a screenshot box with the exact frame of the control under it.
    mutating func refineScreenRect(_ rect: CGRect) {
        guard phase == .waiting, step?.screenRect != nil, step?.outsideWindow == false else { return }
        step?.screenRect = GoFrame(rect)
    }
    mutating func stamp(_ hash: Int, windowFrame: GoFrame? = nil) { step?.contextHash = hash; step?.windowFrame = windowFrame }
    /// Go asks the owner before a step; the step itself is kept to resume on "yes".
    mutating func askBeforeStep(_ question: String) { phase = .needsInput; message = question; firstMatchAt = nil; offTrackAt = nil }

    /// Carries the planner's risk judgement onto the accepted step. When the owner
    /// is doing a risky step themselves, the instruction starts with a short heads-up.
    mutating func applyRisk(_ risk: GoRisk?, warnOwner: Bool) {
        guard phase == .waiting, var risk else { return }
        // A shortcut that can close or delete is asked about, whatever the planner judged.
        if risk.level == .none, step?.keyboard == true, step?.keys.flatMap(GoKeyCombo.parse)?.needsConfirmation == true {
            risk = GoRisk(level: .confirm, reason: "that shortcut can close or delete things")
        }
        step?.risk = risk
        guard warnOwner, risk.level != .none else { return }
        let reason = risk.reason.flatMap { UntrustedText($0).isPlausibleControlLabel ? $0 : nil } ?? "this one can't easily be undone"
        message = "Heads up: \(reason). " + message
    }
    mutating func prefixMessage(_ prefix: String) { if phase == .waiting || phase == .needsInput { message = prefix + message } }
    mutating func stop(_ reason: String) { phase = .stopped; step = nil; message = reason; firstMatchAt = nil }
    mutating func ask(_ reason: String) { phase = .needsInput; step = nil; message = reason; firstMatchAt = nil }

    mutating func accept(_ proposal: GoStepProposal, from observation: GoObservation) {
        app = observation.app
        boxLandedOn = nil
        guard !proposal.instruction.isEmpty, proposal.instruction.count <= 240 else {
            return ask("I couldn't form a short, clear next step.")
        }
        if proposal.kind == .ask { return ask(proposal.instruction) }
        // An answer ends the request: it is final, like done, and its bubble clears.
        if proposal.kind == .answer {
            phase = .done; step = nil; message = proposal.instruction; firstMatchAt = nil; offTrackAt = nil
            return
        }
        if proposal.kind == .reveal {
            let direction = ["down", "up"].contains(proposal.scroll ?? "") ? proposal.scroll : nil
            step = GoWalkthroughStep(instruction: proposal.instruction, app: observation.app, windowToken: observation.windowToken,
                                     control: nil, menu: nil, expected: nil, windowName: observation.windowName,
                                     screenLabel: proposal.label.flatMap { UntrustedText($0).isPlausibleControlLabel ? $0 : nil },
                                     reveal: true, scrollDirection: direction)
            message = proposal.instruction; phase = .waiting
            firstMatchAt = nil; offTrackAt = nil
            return
        }
        if proposal.targetID == "keyboard" {
            guard proposal.kind == .step else { return ask("I couldn't form a keyboard step here.") }
            var text = proposal.typeText
            if text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true { text = nil }
            let combo = proposal.keys.flatMap(GoKeyCombo.parse)
            if proposal.keys != nil, combo == nil { return ask("I couldn't work out which keys to press.") }
            guard text != nil || combo != nil, (text?.count ?? 0) <= 500 else { return ask("What should I type there?") }
            if let refusal = combo?.refusal { return ask(refusal.prefix(1).uppercased() + refusal.dropFirst() + ".") }
            var instruction = proposal.instruction
            if let text, !instruction.contains(text) { instruction += " Type \u{201C}\(text)\u{201D}." }
            if let combo, !instruction.contains(combo.display) { instruction += " (\(combo.display))" }
            step = GoWalkthroughStep(instruction: instruction, app: observation.app, windowToken: observation.windowToken,
                                     control: nil, menu: nil, expected: nil, typeText: text, windowName: observation.windowName,
                                     keys: proposal.keys, keyboard: true)
            message = instruction; phase = .waiting
            firstMatchAt = nil; offTrackAt = nil
            return
        }
        let system = proposal.targetID.flatMap { id in observation.systemControls.first { $0.id == id } }
        if proposal.targetID == "screen" || system != nil {
            let plannedLabel = proposal.label.flatMap { UntrustedText($0).isPlausibleControlLabel ? $0 : nil }
            var rect: CGRect
            var label = plannedLabel ?? system?.name ?? "that control"
            var outside = system != nil
            var outsideName = system?.name
            if let system {
                rect = system.frame.rect
            } else {
                guard let boxed = observation.screenRect(forBox: proposal.box) else {
                    return ask("I couldn't pin down where that is. Can you point me to it?")
                }
                rect = boxed
                // A box on a listed menu-bar icon or Dock item uses that item's exact frame,
                // when the planner's label means that item. A label naming something
                // else makes the box off target: never act on another app's icon.
                switch observation.systemControlMatch(near: boxed, label: plannedLabel ?? proposal.instruction) {
                case .snap(let snapped):
                    rect = snapped.frame.rect; label = plannedLabel ?? snapped.name; outside = true; outsideName = snapped.name
                case .offTarget(let item):
                    boxLandedOn = item
                    return ask("I couldn't pin down where that is. Can you point me to it?")
                case .none:
                    break
                }
            }
            guard proposal.kind == .step || proposal.kind == .point else {
                return ask("I couldn't pin down where that is. Can you point me to it?")
            }
            var text = proposal.typeText?.trimmingCharacters(in: .whitespacesAndNewlines)
            if text?.isEmpty == true { text = nil }
            var instruction = proposal.instruction
            if let text, !instruction.localizedCaseInsensitiveContains(text) { instruction += " Type \u{201C}\(text)\u{201D}." }
            if text != nil, proposal.pressReturn == true, !instruction.localizedCaseInsensitiveContains("return") { instruction += " Then press Return." }
            step = GoWalkthroughStep(instruction: instruction, app: observation.app, windowToken: observation.windowToken,
                                     control: nil, menu: nil, expected: nil, typeText: text,
                                     final: proposal.kind == .point, pressReturn: text != nil && proposal.pressReturn == true,
                                     opens: proposal.open == true, windowName: observation.windowName,
                                     screenRect: GoFrame(rect), screenLabel: label, outsideWindow: outside,
                                     outsideName: outsideName)
            message = instruction; phase = .waiting
            firstMatchAt = nil; offTrackAt = nil
            return
        }
        if proposal.kind == .launch {
            guard let name = proposal.app?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty, name.count <= 80,
                  UntrustedText(name).isPlausibleControlLabel else { return ask("Which app should I open?") }
            step = GoWalkthroughStep(instruction: proposal.instruction, app: observation.app, windowToken: observation.windowToken,
                                     control: nil, menu: nil, expected: nil, launchApp: name)
            message = proposal.instruction; phase = .waiting
            firstMatchAt = nil; offTrackAt = nil
            return
        }
        if proposal.kind == .done {
            // Completion is only credible after at least one step really happened.
            guard !verifiedSteps.isEmpty else { return ask("Is that done, or is there more to do?") }
            phase = .done; step = nil; message = proposal.instruction; firstMatchAt = nil; offTrackAt = nil
            return
        }
        if let id = proposal.targetID, let field = observation.fields.first(where: { $0.id == id }) {
            if proposal.kind == .point {
                step = GoWalkthroughStep(instruction: proposal.instruction, app: observation.app, windowToken: observation.windowToken,
                                         control: nil, menu: nil, expected: nil, field: field, typeText: nil, final: true)
                message = proposal.instruction; phase = .waiting
                firstMatchAt = nil; offTrackAt = nil
                return
            }
            guard let text = proposal.typeText?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty, text.count <= 120 else {
                return ask("What would you like to type there?")
            }
            var instruction = proposal.instruction
            if !instruction.localizedCaseInsensitiveContains(text) { instruction += " Type \u{201C}\(text)\u{201D}." }
            let pressReturn = proposal.pressReturn == true
            if pressReturn, !instruction.localizedCaseInsensitiveContains("return") { instruction += " Then press Return." }
            step = GoWalkthroughStep(instruction: instruction, app: observation.app, windowToken: observation.windowToken,
                                     control: nil, menu: nil, expected: nil, field: field, typeText: text, pressReturn: pressReturn)
            message = instruction
            phase = .waiting
            firstMatchAt = nil; offTrackAt = nil
            return
        }
        // A partial read can still name a real target; only expected states need a complete one.
        guard let id = proposal.targetID else { return ask("I couldn't find a control for the next step here.") }
        // A predicted result is optional: clicks on the pointed target complete steps.
        // One that already holds (or cannot change) is dropped, not treated as a failure.
        let expected = proposal.expected.flatMap { $0.canObserveChange(from: observation) ? $0 : nil }
        let control = observation.controls.first { $0.id == id }
        let menu = observation.menus.first { $0.id == id }
        guard control != nil || menu != nil else { return ask("That control is no longer available.") }
        if let control, observation.matches(role: control.role, name: control.name).count != 1 {
            return ask("More than one control matches. Please identify the one you mean.")
        }
        step = GoWalkthroughStep(instruction: proposal.instruction, app: observation.app, windowToken: observation.windowToken,
                                 control: control, menu: menu, expected: expected)
        step?.final = proposal.kind == .point
        step?.opens = proposal.open == true && control != nil
        step?.windowName = observation.windowName
        message = proposal.instruction
        phase = .waiting
        firstMatchAt = nil
    }

    /// The owner went somewhere else: the step's window was replaced, or its
    /// target control is gone, without the expected result. Two reads apart
    /// are required, so a transition in progress is not called a mistake.
    mutating func noteOffTrack(_ observation: GoObservation, now: TimeInterval) -> Bool {
        guard phase == .waiting, let step, observation.app == step.app, observation.complete, !step.opens, step.launchApp == nil, !step.reveal,
              step.expected?.isSatisfied(in: observation) != true else { offTrackAt = nil; return false }
        let windowReplaced = observation.windowToken != step.windowToken
            && (step.expected?.kind != .windowAppeared || !observation.windowName.isEmpty)
        let targetGone = observation.windowToken == step.windowToken && step.expected?.kind != .elementDisappeared
            && step.control.map { observation.matches(role: $0.role, name: $0.name).isEmpty } == true
        guard windowReplaced || targetGone else { offTrackAt = nil; offTrackReported = false; return false }
        guard let first = offTrackAt else { offTrackAt = now; return false }
        guard now - first >= 0.6, !offTrackReported else { return false }
        // The step stays pending: the owner is sent back to it, not given a new plan.
        offTrackReported = true
        return true
    }

    /// The owner clicked the pointed final target and the UI settled: the step
    /// was done by hand, as Go treats it. The next plan reads the new screen,
    /// so a click that changed nothing simply yields the same step again.
    mutating func completeByClick(_ clicked: GoWalkthroughStep) -> Bool {
        guard phase == .waiting, step == clicked, let step else { return false }
        advance(step)
        return true
    }

    /// Two fresh reads separated by quiet time are required. An unrelated app,
    /// partial read, or changed document cannot complete a value/absence check.
    mutating func observe(_ observation: GoObservation, now: TimeInterval) -> Bool {
        guard phase == .waiting, let step else { return false }
        guard observation.app == step.app, observation.complete else { firstMatchAt = nil; return false }
        // Opening a folder replaces the window: that is the step working.
        if step.opens, observation.windowToken != step.windowToken || observation.windowName != step.windowName {
            guard let first = firstMatchAt else { firstMatchAt = now; return false }
            guard now - first >= 0.25 else { return false }
            advance(step)
            return true
        }
        guard let expected = step.expected else { return false }
        if observation.windowToken != step.windowToken, expected.kind != .windowAppeared {
            firstMatchAt = nil
            return false
        }
        guard expected.isSatisfied(in: observation) else { firstMatchAt = nil; return false }
        guard let first = firstMatchAt else { firstMatchAt = now; return false }
        guard now - first >= 0.25 else { return false }
        advance(step)
        return true
    }
}
