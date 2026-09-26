//
//  ElementActionIntent.swift
//  Go
//
//  A structured request to act on one element, the resolver that finds exactly
//  that element (or refuses), and the performers that press, select and type.
//

import AppKit
import ApplicationServices
import Foundation

nonisolated enum ElementAction {
    case press

    /// Selecting is a property write (`AXSelected`), not an action; many sidebar
    /// rows publish no `AXPress`.
    case select

    /// Typing is a property write too; which property depends on `TypeMode`.
    case type

    /// Opening (`AXOpen`): how Finder opens a file item.
    case open

    /// Pressing a menu item, found by its path down the menu bar.
    case menu

    /// The published action this needs, or nil for a property write.
    var accessibilityActionName: String? {
        switch self {
        case .press, .menu:
            return kAXPressAction
        case .open:
            return "AXOpen"
        case .select, .type:
            return nil
        }
    }

    /// Whether an irreversible title refuses this verb. False for `select`:
    /// selecting a row named "Purchased" buys nothing.
    var irreversibleNamesAreRefused: Bool {
        switch self {
        case .press, .type, .open, .menu: return true
        case .select: return false
        }
    }

    /// Whether the target is drawn on screen, so its frame can be checked.
    /// False for menu items, which have no frame while the menu is closed.
    var targetHasAnOnScreenFrame: Bool {
        switch self {
        case .press, .select, .type, .open: return true
        case .menu: return false
        }
    }
}

/// Replace the whole field (`AXValue`) or insert at the caret (`AXSelectedText`).
nonisolated enum TypeMode: String, Equatable, CaseIterable {
    case insert
    case replace

    /// The attribute this mode writes, which the element must report as settable.
    var settableAttributeRequired: String {
        switch self {
        case .insert: return kAXSelectedTextAttribute
        case .replace: return kAXValueAttribute
        }
    }
}

nonisolated struct ElementActionIntent {
    let role: String?
    let title: String
    let action: ElementAction

    /// Roughly where the target is on screen (AppKit coordinates), to choose
    /// between elements that share a name.
    var nearPoint: CGPoint? = nil

    /// The name of a container the target sits inside ("Back in the toolbar").
    var withinNamed: String? = nil
}

nonisolated enum IntentResolution: Equatable {
    case resolved(AccessibilityElementNode)
    case notFound
    case ambiguous(matchCount: Int)

    static func == (lhs: IntentResolution, rhs: IntentResolution) -> Bool {
        switch (lhs, rhs) {
        case (.notFound, .notFound):
            return true
        case (.ambiguous(let leftCount), .ambiguous(let rightCount)):
            return leftCount == rightCount
        case (.resolved(let leftNode), .resolved(let rightNode)):
            return leftNode.role == rightNode.role
                && leftNode.title == rightNode.title
                && leftNode.frameInAppKitCoordinates == rightNode.frameInAppKitCoordinates
        default:
            return false
        }
    }
}

nonisolated enum ElementActionIntentResolver {

    /// Finds every node whose title (and role, if given) matches. More than one
    /// match is a refusal, never a guess.
    static func resolve(
        _ intent: ElementActionIntent,
        inTreeRootedAt rootNode: AccessibilityElementNode
    ) -> IntentResolution {
        var matchingNodes: [(node: AccessibilityElementNode, ancestorNames: [String])] = []
        collectMatches(in: rootNode, ancestorNames: [], for: intent, into: &matchingNodes)

        // Narrow by container name first (structure), then by point. A hint that
        // matches nothing narrows nothing.
        var candidates = matchingNodes
        if candidates.count > 1, let container = intent.withinNamed {
            let narrowed = candidates.filter { $0.ancestorNames.contains(container) }
            if !narrowed.isEmpty { candidates = narrowed }
        }
        if candidates.count > 1, let point = intent.nearPoint {
            let narrowed = candidates.filter { $0.node.frameInAppKitCoordinates.contains(point) }
            if !narrowed.isEmpty { candidates = narrowed }
        }

        switch candidates.count {
        case 0:
            return .notFound
        case 1:
            return .resolved(candidates[0].node)
        default:
            // Still ambiguous: refuse rather than pick the nearest.
            return .ambiguous(matchCount: matchingNodes.count)
        }
    }

    /// One match, with the container name that picks it out alone, or nil.
    struct ContainerSuggestion {
        let node: AccessibilityElementNode
        let suggestedWithinNamed: String?
    }

    /// For each match, the nearest named ancestor no other match sits inside,
    /// computed on the same match set `withinNamed` narrows.
    static func containerSuggestions(
        for intent: ElementActionIntent,
        inTreeRootedAt rootNode: AccessibilityElementNode
    ) -> [ContainerSuggestion] {
        var matches: [(node: AccessibilityElementNode, ancestorNames: [String])] = []
        collectMatches(in: rootNode, ancestorNames: [], for: intent, into: &matches)

        var matchesInside: [String: Int] = [:]
        for match in matches {
            for name in Set(match.ancestorNames) { matchesInside[name, default: 0] += 1 }
        }

        return matches.map { match in
            let separating = match.ancestorNames.reversed().first { name in
                // Skip implausible names; keep walking up.
                matchesInside[name] == 1 && UntrustedText(name).isPlausibleControlLabel
            }
            return ContainerSuggestion(node: match.node, suggestedWithinNamed: separating)
        }
    }

    /// Every match with the names of the containers it sits inside.
    private static func collectMatches(
        in node: AccessibilityElementNode,
        ancestorNames: [String],
        for intent: ElementActionIntent,
        into matches: inout [(node: AccessibilityElementNode, ancestorNames: [String])]
    ) {
        // Compare only: the planner's title is matched against the app's text.
        let name = node.displayName?.raw
        if name == intent.title, intent.role == nil || node.role == intent.role {
            matches.append((node, ancestorNames))
        }

        let chainBelow = name.map { ancestorNames + [$0] } ?? ancestorNames
        for child in node.children {
            collectMatches(in: child, ancestorNames: chainBelow, for: intent, into: &matches)
        }
    }
}

/// Performs AX actions with a per-element timeout, separate from the short
/// read timeout the walker uses (actions wait for animations).
nonisolated enum AccessibilityActionPerformer {

    static let actionTimeoutInSeconds: Float = 5.0

    /// Returns the elapsed time too: the same error in 2 ms (app refused) and
    /// 5 s (our timeout) mean different things.
    static func perform(
        _ actionName: String,
        on element: AXUIElement,
        timeoutInSeconds: Float = actionTimeoutInSeconds
    ) -> (error: AXError, milliseconds: Int) {
        AXUIElementSetMessagingTimeout(element, timeoutInSeconds)
        let startedAt = Date()
        let error = AXUIElementPerformAction(element, actionName as CFString)
        return (error, Int(Date().timeIntervalSince(startedAt) * 1000))
    }
}

/// Selecting a row. Writing the container's `AXSelectedRows` works in both
/// System Settings and Finder, so it is tried first; the row's own `AXSelected`
/// is the fallback. Sidebar rows are anonymous, so we walk up from the named
/// label to the first ancestor that is selectable.
nonisolated enum AccessibilitySelectionPerformer {

    static let selectedAttribute = "AXSelected"

    /// Selection attributes tried on the container, in order.
    static let containerSelectionAttributes = ["AXSelectedRows", "AXSelectedChildren"]
    static let selectionTimeoutInSeconds: Float = 5.0

    enum SelectionPath: String, Equatable {
        case containerSelectedRows = "AXSelectedRows on the container"
        case containerSelectedChildren = "AXSelectedChildren on the container"
        case elementSelected = "AXSelected on the element itself"
    }

    enum Outcome: Equatable {
        case selected(path: SelectionPath, levelsAboveTarget: Int, milliseconds: Int, readBackTrue: Bool)
        /// The container already has this row selected; nothing was written.
        case alreadySelected(path: SelectionPath, levelsAboveTarget: Int)
        case writeFailed(error: AXError, levelsAboveTarget: Int, milliseconds: Int)
        case noSelectableAncestor(levelsInspected: Int)
        case noLiveElement
    }

    /// Root-to-target path, so the selection can walk up from the named label.
    static func ancestorChain(
        to target: AccessibilityElementNode,
        from node: AccessibilityElementNode
    ) -> [AccessibilityElementNode]? {
        if node.role == target.role,
           node.displayName == target.displayName,
           node.frameInAppKitCoordinates == target.frameInAppKitCoordinates {
            return [node]
        }
        for child in node.children {
            if let tail = ancestorChain(to: target, from: child) {
                return [node] + tail
            }
        }
        return nil
    }

    /// `chainFromRoot`: root first, named element last.
    static func select(chainFromRoot: [AccessibilityElementNode]) -> Outcome {
        guard !chainFromRoot.isEmpty else { return .noLiveElement }

        var sawALiveElement = false
        for (levelsUp, node) in chainFromRoot.reversed().enumerated() {
            guard let element = node.accessibilityElement else { continue }
            sawALiveElement = true
            guard isSelectable(element) else { continue }

            AXUIElementSetMessagingTimeout(element, selectionTimeoutInSeconds)

            let rowIndex = chainFromRoot.count - 1 - levelsUp
            let container = rowIndex > 0 ? chainFromRoot[rowIndex - 1].accessibilityElement : nil

            var lastError: AXError = .success
            var lastMilliseconds = 0

            if let container {
                AXUIElementSetMessagingTimeout(container, selectionTimeoutInSeconds)
                for attribute in containerSelectionAttributes where isSettable(container, attribute) {
                    let path: SelectionPath = attribute == "AXSelectedRows" ? .containerSelectedRows : .containerSelectedChildren

                    // Skip the write if the container already has exactly this selection.
                    // The row's own `AXSelected` is not trusted: Finder reports true without navigating.
                    var current: CFTypeRef?
                    if AXUIElementCopyAttributeValue(container, attribute as CFString, &current) == .success,
                       let selectedElements = current as? [AXUIElement],
                       selection(selectedElements, isExactly: element) {
                        return .alreadySelected(path: path, levelsAboveTarget: levelsUp)
                    }

                    let startedAt = Date()
                    let error = AXUIElementSetAttributeValue(
                        container, attribute as CFString, [element] as CFArray
                    )
                    lastMilliseconds = Int(Date().timeIntervalSince(startedAt) * 1000)
                    lastError = error
                    guard error == .success else { continue }
                    return .selected(
                        path: path,
                        levelsAboveTarget: levelsUp,
                        milliseconds: lastMilliseconds,
                        readBackTrue: readsBackSelected(element)
                    )
                }
            }

            let startedAt = Date()
            let error = AXUIElementSetAttributeValue(
                element, selectedAttribute as CFString, kCFBooleanTrue
            )
            let milliseconds = Int(Date().timeIntervalSince(startedAt) * 1000)

            guard error == .success else {
                return .writeFailed(
                    error: error == .success ? lastError : error,
                    levelsAboveTarget: levelsUp,
                    milliseconds: milliseconds
                )
            }

            return .selected(
                path: .elementSelected,
                levelsAboveTarget: levelsUp,
                milliseconds: milliseconds,
                readBackTrue: readsBackSelected(element)
            )
        }

        return sawALiveElement
            ? .noSelectableAncestor(levelsInspected: chainFromRoot.count)
            : .noLiveElement
    }

    /// Reads the selection back; still not proof the app acted on it.
    static func readsBackSelected(_ element: AXUIElement) -> Bool {
        var readBack: AnyObject?
        AXUIElementCopyAttributeValue(element, selectedAttribute as CFString, &readBack)
        return (readBack as? Bool) == true
    }

    /// Exact match, not "contains": the write replaces the whole selection.
    static func selection(_ selectedElements: [AXUIElement], isExactly element: AXUIElement) -> Bool {
        selectedElements.count == 1
            && AccessibilityElementKey(element: selectedElements[0]) == AccessibilityElementKey(element: element)
    }

    static func isSettable(_ element: AXUIElement, _ attribute: String) -> Bool {
        var isSettable: DarwinBoolean = false
        let error = AXUIElementIsAttributeSettable(element, attribute as CFString, &isSettable)
        return error == .success && isSettable.boolValue
    }

    /// Asks the element whether `AXSelected` is settable.
    static func isSelectable(_ element: AXUIElement) -> Bool {
        isSettable(element, selectedAttribute)
    }
}

/// Typing into a field. Asks the element what is settable, then reads the
/// value back: for typing, the text is the evidence.
nonisolated enum AccessibilityTypePerformer {

    static let typingTimeoutInSeconds: Float = 5.0

    /// Attributes probed before a write, on one element only.
    static let probedAttributes = [
        kAXValueAttribute, kAXSelectedTextAttribute,
        kAXSelectedTextRangeAttribute, kAXFocusedAttribute
    ]

    struct Outcome: Equatable {
        let attributeWritten: String
        let error: AXError
        let milliseconds: Int
        let valueLengthBefore: Int
        /// nil when the field would not answer after the write.
        let valueAfter: String?
    }

    static func stringValue(of element: AXUIElement) -> String? {
        var out: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &out) == .success else {
            return nil
        }
        return out as? String
    }

    /// Which attributes the element says it accepts; the read-back confirms.
    static func settableAttributes(of element: AXUIElement) -> Set<String> {
        Set(probedAttributes.filter { AccessibilitySelectionPerformer.isSettable(element, $0) })
    }

    /// The focused element in the frontmost app. Text fields are often anonymous,
    /// so this is how they are reached. Read directly, since focus may be in a
    /// sheet or popover the window walk skipped.
    static func focusedNode() -> AccessibilityElementNode? {
        // Same app source as the snapshot.
        guard let application = AccessibilityTreeWalker.focusedApplication() else { return nil }
        let applicationElement = AXUIElementCreateApplication(application.processIdentifier)

        var focusedValue: AnyObject?
        guard AXUIElementCopyAttributeValue(
            applicationElement, kAXFocusedUIElementAttribute as CFString, &focusedValue
        ) == .success,
            let focusedValue,
            CFGetTypeID(focusedValue) == AXUIElementGetTypeID() else { return nil }
        let element = focusedValue as! AXUIElement

        func string(_ attribute: String) -> String? {
            var out: AnyObject?
            guard AXUIElementCopyAttributeValue(element, attribute as CFString, &out) == .success,
                  let text = out as? String, !text.isEmpty else { return nil }
            return text
        }

        let primaryDisplayHeight = CGDisplayBounds(CGMainDisplayID()).height
        let accessibilityFrame = frame(of: element) ?? .zero

        return AccessibilityElementNode(
            role: string(kAXRoleAttribute) ?? "AXUnknown",
            subrole: string(kAXSubroleAttribute),
            title: string(kAXTitleAttribute),
            value: string(kAXValueAttribute),
            elementDescription: string(kAXDescriptionAttribute),
            frameInAppKitCoordinates: AccessibilityTreeWalker.convertAccessibilityFrameToAppKitFrame(
                accessibilityFrame, primaryDisplayHeightInPoints: primaryDisplayHeight
            ),
            depth: 0,
            children: [],
            publishedActionNames: AccessibilityTreeWalker.copyActionNames(from: element),
            accessibilityElement: element
        )
    }

    /// `AXFrame`, else position and size (not every app publishes `AXFrame`).
    private static func frame(of element: AXUIElement) -> CGRect? {
        var frameValue: AnyObject?
        if AXUIElementCopyAttributeValue(element, "AXFrame" as CFString, &frameValue) == .success,
           let frameValue, CFGetTypeID(frameValue) == AXValueGetTypeID() {
            var rect = CGRect.zero
            if AXValueGetValue(frameValue as! AXValue, .cgRect, &rect) { return rect }
        }

        var positionValue: AnyObject?
        var sizeValue: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionValue, let sizeValue,
              CFGetTypeID(positionValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return nil }

        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &position),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: position, size: size)
    }

    /// Writes `text` into `element`. `.insert` moves the caret to the end first,
    /// so it never replaces a selected value. Ranges are in UTF-16 units.
    static func type(_ text: String, mode: TypeMode, into element: AXUIElement) -> Outcome {
        AXUIElementSetMessagingTimeout(element, typingTimeoutInSeconds)

        let valueBefore = stringValue(of: element) ?? ""
        let startedAt = Date()
        let error: AXError

        switch mode {
        case .replace:
            error = AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, text as CFString)
        case .insert:
            var caret = CFRange(location: valueBefore.utf16.count, length: 0)
            if let caretValue = AXValueCreate(.cfRange, &caret) {
                AXUIElementSetAttributeValue(
                    element, kAXSelectedTextRangeAttribute as CFString, caretValue
                )
            }
            error = AXUIElementSetAttributeValue(
                element, kAXSelectedTextAttribute as CFString, text as CFString
            )
        }

        return Outcome(
            attributeWritten: mode.settableAttributeRequired,
            error: error,
            milliseconds: Int(Date().timeIntervalSince(startedAt) * 1000),
            valueLengthBefore: valueBefore.count,
            valueAfter: stringValue(of: element)
        )
    }
}

/// The menu bar, read from the application element (not a window). Paths are
/// resolved one level at a time; each menu-bar item holds a single `AXMenu`
/// wrapper, and submenus are readable without being opened.
nonisolated enum AccessibilityMenu {

    static let menuBarRole = "AXMenuBar"
    static let menuRole = "AXMenu"
    static let menuItemRole = "AXMenuItem"
    static let menuBarItemRole = "AXMenuBarItem"

    static let enabledAttribute = "AXEnabled"
    static let cmdCharAttribute = "AXMenuItemCmdChar"
    static let cmdModifiersAttribute = "AXMenuItemCmdModifiers"
    /// A checkmark character when the item is ticked.
    static let markCharAttribute = "AXMenuItemMarkChar"

    static let messagingTimeoutInSeconds: Float = 0.5

    /// Listings are bounded and say which limit stopped them.
    static let maximumItemsListed = 3_000
    static let listingTimeLimitInSeconds = 5.0

    /// One menu element. Live reads fetch children through a closure, so
    /// resolving a path reads only that path.
    struct Node {
        let label: String?
        let role: String
        let isEnabled: Bool
        let shortcut: String?
        let isMarked: Bool
        let element: AXUIElement?
        let children: [Node]

        init(
            label: String?,
            role: String,
            isEnabled: Bool = true,
            shortcut: String? = nil,
            isMarked: Bool = false,
            element: AXUIElement? = nil,
            children: [Node] = []
        ) {
            self.label = label
            self.role = role
            self.isEnabled = isEnabled
            self.shortcut = shortcut
            self.isMarked = isMarked
            self.element = element
            self.children = children
        }
    }

    // MARK: - Resolution

    enum StepOutcome: Equatable {
        case matched(index: Int)
        case notFound(available: [String])
        case ambiguous(matchCount: Int)
    }

    enum Resolution: Equatable {
        case resolved(label: String?, role: String, isEnabled: Bool)
        case notFound(atStep: Int, step: String, available: [String])
        case ambiguous(atStep: Int, step: String, matchCount: Int)
        case emptyPath
    }

    /// One path step against one level. Several matches is a question, never
    /// the first one.
    static func match(step: String, among candidates: [Node]) -> StepOutcome {
        let indices = candidates.indices.filter { candidates[$0].label == step }
        switch indices.count {
        case 1: return .matched(index: indices[0])
        case 0: return .notFound(available: candidates.compactMap(\.label))
        default: return .ambiguous(matchCount: indices.count)
        }
    }

    /// Items one level down, through the `AXMenu` wrapper.
    static func entries(of node: Node, children: (Node) -> [Node]) -> [Node] {
        let direct = children(node)
        if direct.count == 1, direct[0].role == menuRole { return children(direct[0]) }
        return direct
    }

    /// nil for a leaf; otherwise the submenu's item labels.
    static func submenuChildLabels(of node: Node, children: (Node) -> [Node]) -> [String]? {
        let inside = entries(of: node, children: children)
        return inside.isEmpty ? nil : inside.compactMap(\.label)
    }

    /// Walks only the path. `children` is a live AX read, or a test tree.
    static func resolveNode(
        path: [String],
        from root: Node,
        children: (Node) -> [Node]
    ) -> (node: Node?, resolution: Resolution) {
        guard !path.isEmpty else { return (nil, .emptyPath) }

        var current = root
        for (index, step) in path.enumerated() {
            let candidates = entries(of: current, children: children)
            switch match(step: step, among: candidates) {
            case .matched(let matchedIndex):
                current = candidates[matchedIndex]
            case .notFound(let available):
                return (nil, .notFound(atStep: index, step: step, available: available))
            case .ambiguous(let matchCount):
                return (nil, .ambiguous(atStep: index, step: step, matchCount: matchCount))
            }
        }
        return (current, .resolved(label: current.label, role: current.role, isEnabled: current.isEnabled))
    }

    // MARK: - Listing

    struct ListedItem {
        let path: [String]
        let role: String
        let isEnabled: Bool
        let shortcut: String?
        let hasSubmenu: Bool
        let isMarked: Bool
    }

    struct Listing {
        let items: [ListedItem]
        let milliseconds: Int
        /// Empty means the listing finished.
        let stopReasons: [String]
    }

    /// Everything at or below `start`, with each item's full path.
    static func list(
        from start: Node,
        pathSoFar: [String],
        children: (Node) -> [Node],
        deadline: Date
    ) -> Listing {
        let startedAt = Date()
        var items: [ListedItem] = []
        var stopReasons: Set<String> = []
        collect(start, pathSoFar: pathSoFar, children: children, deadline: deadline,
                items: &items, stopReasons: &stopReasons)
        return Listing(
            items: items,
            milliseconds: Int(Date().timeIntervalSince(startedAt) * 1000),
            stopReasons: stopReasons.sorted()
        )
    }

    private static func collect(
        _ node: Node,
        pathSoFar: [String],
        children: (Node) -> [Node],
        deadline: Date,
        items: inout [ListedItem],
        stopReasons: inout Set<String>
    ) {
        guard items.count < maximumItemsListed else {
            stopReasons.insert(WalkStopReason.nodeLimit.rawValue)
            return
        }
        guard Date() < deadline else {
            stopReasons.insert(WalkStopReason.timeLimit.rawValue)
            return
        }

        let childNodes = entries(of: node, children: children)

        if node.role == menuItemRole || node.role == menuBarItemRole {
            items.append(ListedItem(
                path: pathSoFar,
                role: node.role,
                isEnabled: node.isEnabled,
                shortcut: node.shortcut,
                hasSubmenu: !childNodes.isEmpty,
                isMarked: node.isMarked
            ))
        }

        for child in childNodes {
            guard let label = child.label else { continue }
            collect(child, pathSoFar: pathSoFar + [label], children: children,
                    deadline: deadline, items: &items, stopReasons: &stopReasons)
        }
    }

    // MARK: - Shortcuts

    /// Formats a menu shortcut. `AXMenuItemCmdModifiers` encodes Command by its
    /// absence: bit 3 set means no Command; bits 0-2 are Shift, Option, Control.
    static func describeShortcut(character: String?, modifiers: Int?) -> String? {
        guard let character, !character.isEmpty else { return nil }
        let mask = modifiers ?? 0
        var text = ""
        // Apple's display order: ⌃⌥⇧⌘, then the key.
        if mask & 4 != 0 { text += "⌃" }
        if mask & 2 != 0 { text += "⌥" }
        if mask & 1 != 0 { text += "⇧" }
        if mask & 8 == 0 { text += "⌘" }
        return text + readableKey(character)
    }

    /// Readable names for control-character keys.
    static let readableKeys: [Character: String] = [
        "\u{8}": "⌫", "\u{9}": "⇥", "\u{d}": "↩", "\u{1b}": "⎋", "\u{7f}": "⌦", " ": "␣"
    ]

    static func readableKey(_ character: String) -> String {
        if let first = character.first, let symbol = readableKeys[first] { return symbol }
        return character.uppercased()
    }

    // MARK: - Live reads

    static func menuBarNode(for application: NSRunningApplication) -> Node? {
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), messagingTimeoutInSeconds)

        let applicationElement = AXUIElementCreateApplication(application.processIdentifier)
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(
            applicationElement, kAXMenuBarAttribute as CFString, &value
        ) == .success,
            let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }

        return Node(label: nil, role: menuBarRole, element: (value as! AXUIElement))
    }

    /// Child attributes, read in one batched call per level.
    static let batchedAttributes = [
        kAXRoleAttribute, kAXTitleAttribute, enabledAttribute,
        cmdCharAttribute, cmdModifiersAttribute, kAXChildrenAttribute, markCharAttribute
    ]

    static func liveChildren(of node: Node) -> [Node] {
        guard let element = node.element else { return [] }

        var childrenValue: AnyObject?
        let result = AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenValue)
        guard result == .success, let childElements = childrenValue as? [AXUIElement] else { return [] }

        return childElements.map { childElement in
            var rawValues: CFArray?
            let batchResult = AXUIElementCopyMultipleAttributeValues(
                childElement, batchedAttributes as CFArray, AXCopyMultipleAttributeOptions(), &rawValues
            )
            let values = (batchResult == .success ? rawValues as? [AnyObject] : nil) ?? []

            func entry(_ index: Int) -> AnyObject? {
                guard index < values.count else { return nil }
                let value = values[index]
                // A failed attribute comes back as an AXValue wrapping an AXError.
                if CFGetTypeID(value) == AXValueGetTypeID(),
                   AXValueGetType(value as! AXValue) == .axError { return nil }
                return value
            }

            let title = entry(1) as? String
            return Node(
                label: (title?.isEmpty == false) ? title : nil,
                role: (entry(0) as? String) ?? "AXUnknown",
                // Missing `AXEnabled` counts as enabled; only a real false refuses.
                isEnabled: (entry(2) as? Bool) ?? true,
                shortcut: describeShortcut(
                    character: entry(3) as? String,
                    modifiers: (entry(4) as? NSNumber)?.intValue
                ),
                isMarked: (entry(6) as? String).map { !$0.isEmpty } ?? false,
                element: childElement
            )
        }
    }

    /// The resolved item as a kernel node; frame and actions are read only here.
    static func elementNode(for node: Node) -> AccessibilityElementNode {
        let element = node.element
        var frame = CGRect.zero
        if let element {
            var frameValue: AnyObject?
            if AXUIElementCopyAttributeValue(element, "AXFrame" as CFString, &frameValue) == .success,
               let frameValue, CFGetTypeID(frameValue) == AXValueGetTypeID() {
                var rect = CGRect.zero
                if AXValueGetValue(frameValue as! AXValue, .cgRect, &rect) { frame = rect }
            }
        }
        let primaryDisplayHeight = CGDisplayBounds(CGMainDisplayID()).height

        return AccessibilityElementNode(
            role: node.role,
            subrole: nil,
            title: node.label,
            value: nil,
            elementDescription: nil,
            frameInAppKitCoordinates: AccessibilityTreeWalker.convertAccessibilityFrameToAppKitFrame(
                frame, primaryDisplayHeightInPoints: primaryDisplayHeight
            ),
            depth: 0,
            children: [],
            publishedActionNames: element.map(AccessibilityTreeWalker.copyActionNames) ?? [],
            accessibilityElement: element
        )
    }

    /// Window count, for verification: a new window with the same names as an
    /// old one only shows up here.
    static func windowCount(for application: NSRunningApplication) -> Int? {
        let applicationElement = AXUIElementCreateApplication(application.processIdentifier)
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(
            applicationElement, kAXWindowsAttribute as CFString, &value
        ) == .success, let windows = value as? [AXUIElement] else { return nil }
        return windows.count
    }
}
