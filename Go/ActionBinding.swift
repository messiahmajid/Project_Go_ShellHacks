//
//  ActionBinding.swift
//  Go
//
//  A ticket approves words (verb, app, target), but some actions act on
//  whatever is selected when they run. So a ticket also records the target
//  element and the current selection (by identity, plus a fingerprint of the
//  item texts). Both are read again at use; if either moved, the ticket is
//  stale.
//

import AppKit
import ApplicationServices
import CryptoKit
import Foundation

nonisolated struct ActionBinding: Equatable {

    struct PublishedSelection: Equatable {
        let containerKey: AccessibilityElementKey
        let selectedItemKeys: Set<AccessibilityElementKey>
        /// SHA-256 of the selected items' texts; identity alone misses reused rows.
        let namesFingerprint: String
        let count: Int
        /// First text of each selected item, only for apps in
        /// `appsWhoseItemNamesMayBeShown`; nil otherwise (no mail previews on cards).
        let displayNames: [String]?
    }

    enum Selection: Equatable {
        case published(PublishedSelection)
        /// Our words and a raw AXError, never app-written text.
        case unavailable(reason: String)
    }

    /// nil when the verb acts on no element.
    let targetElementKey: AccessibilityElementKey?
    let selection: Selection
    let readMilliseconds: Int

    struct Subject {
        let targetElement: AXUIElement?
        let processIdentifier: pid_t?
    }

    /// Apps whose selected item names may be shown (file names in Finder). Every
    /// other app shows a count.
    static let appsWhoseItemNamesMayBeShown: Set<String> = ["com.apple.finder"]

    static let messagingTimeoutInSeconds: Float = 0.5
    /// How far up from the focused element to look for the selecting container.
    static let maximumAncestorHops = 6
    /// How deep inside one item to look for its texts.
    static let maximumItemTextDepth = 4
    static let maximumNamesShown = 3

    // MARK: Pure

    static func itemNamesMayBeShown(bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier else { return false }
        return appsWhoseItemNamesMayBeShown.contains(bundleIdentifier.lowercased())
    }

    /// Hashes JSON so ["ab"] and ["a","b"] differ.
    static func namesFingerprint(itemTexts: [[String]]) -> String {
        let encoded = (try? JSONEncoder().encode(itemTexts)) ?? Data()
        return SHA256.hash(data: encoded).map { String(format: "%02x", $0) }.joined()
    }

    /// Column view keeps every ancestor column's selection; the last one is what acts.
    static func lastNonEmptyColumnIndex(selectedCountsByColumn: [Int]) -> Int? {
        selectedCountsByColumn.lastIndex { $0 > 0 }
    }

    /// Which part of the binding no longer holds, or nil.
    static func movedPart(approved: ActionBinding, currentTargetKey: AccessibilityElementKey?,
                          currentSelection: Selection) -> String? {
        if approved.targetElementKey != currentTargetKey { return "target" }
        guard case .published(let then) = approved.selection else { return nil }
        guard case .published(let now) = currentSelection,
              now.containerKey == then.containerKey,
              now.selectedItemKeys == then.selectedItemKeys,
              now.namesFingerprint == then.namesFingerprint else { return "selection" }
        return nil
    }

    /// The card's lines for a binding: names only for allowed apps, escaped, at
    /// most three, and counted rather than cut when they don't fit.
    static func displayLines(for binding: ActionBinding, bundleIdentifier: String?) -> [String] {
        guard case .published(let selection) = binding.selection else {
            return ["can't see what this will affect"]
        }
        var lines = ["affects: \(selection.count) selected item\(selection.count == 1 ? "" : "s")"]
        guard itemNamesMayBeShown(bundleIdentifier: bundleIdentifier),
              let names = selection.displayNames, !names.isEmpty else { return lines }
        let budget = HarnessConfirmations.maximumDisplayLineLength
        for shownCount in stride(from: min(maximumNamesShown, names.count), through: 1, by: -1) {
            let remaining = names.count - shownCount
            let line = "selected: "
                + names.prefix(shownCount).map { UntrustedText($0).forDisplayInFull }.joined(separator: ", ")
                + (remaining > 0 ? " and \(remaining) more" : "")
            if line.unicodeScalars.count <= budget {
                lines.append(line)
                return lines
            }
        }
        lines.append("selected: names too long to show in full")
        return lines
    }

    /// What a response carries: names only for allowed apps, never keys or hashes.
    static func responsePayload(_ binding: ActionBinding, bundleIdentifier: String?, stalePart: String? = nil) -> [String: Any] {
        var payload: [String: Any] = ["readMilliseconds": binding.readMilliseconds]
        switch binding.selection {
        case .published(let selection):
            payload["available"] = true
            payload["count"] = selection.count
            if itemNamesMayBeShown(bundleIdentifier: bundleIdentifier), let names = selection.displayNames {
                payload["names"] = names.map { UntrustedText($0).forDisplay }
            }
        case .unavailable(let reason):
            payload["available"] = false
            payload["reason"] = reason
        }
        if let stalePart { payload["stale"] = stalePart }
        return payload
    }

    // MARK: Live reads

    private struct ReadFailure: Error { let reason: String }

    /// "Unsupported" and "no value" mean absent; other errors mean unknown, which
    /// must never read as "no selection".
    private static func isAbsence(_ error: AXError) -> Bool {
        error == .attributeUnsupported || error == .noValue
    }

    private static func element(_ element: AXUIElement, _ attribute: String) throws -> AXUIElement? {
        var value: AnyObject?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        if isAbsence(error) { return nil }
        guard error == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID() else {
            throw ReadFailure(reason: "reading \(attribute) failed: AXError \(error.rawValue)")
        }
        return (value as! AXUIElement)
    }

    private static func elements(_ element: AXUIElement, _ attribute: String) throws -> [AXUIElement]? {
        var value: AnyObject?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        if isAbsence(error) { return nil }
        guard error == .success else {
            throw ReadFailure(reason: "reading \(attribute) failed: AXError \(error.rawValue)")
        }
        return (value as? [AXUIElement]) ?? []
    }

    private static func string(_ element: AXUIElement, _ attribute: String) throws -> String? {
        var value: AnyObject?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        if isAbsence(error) { return nil }
        guard error == .success else {
            throw ReadFailure(reason: "reading \(attribute) failed: AXError \(error.rawValue)")
        }
        return value as? String
    }

    /// Text values in order; image descriptions only when an item has no text.
    private static func texts(of item: AXUIElement) throws -> [String] {
        var values: [String] = []
        var images: [AXUIElement] = []
        func visit(_ element: AXUIElement, depth: Int) throws {
            let role = try string(element, kAXRoleAttribute) ?? ""
            if role == kAXTextFieldRole || role == kAXStaticTextRole, let value = try string(element, kAXValueAttribute) {
                values.append(value)
            } else if role == kAXImageRole {
                images.append(element)
            }
            guard depth < maximumItemTextDepth else { return }
            for child in try elements(element, kAXChildrenAttribute) ?? [] { try visit(child, depth: depth + 1) }
        }
        try visit(item, depth: 0)
        guard values.isEmpty else { return values }
        // Some icons can't be read; skip them. Item keys detect the change anyway.
        return images.compactMap { try? string($0, kAXDescriptionAttribute) ?? nil }
    }

    private static func publishedSelection(container: AXUIElement, attribute: String, items: [AXUIElement],
                                            bundleIdentifier: String?) throws -> PublishedSelection {
        let itemTexts = try items.map(texts(of:))
        return PublishedSelection(
            containerKey: AccessibilityElementKey(element: container),
            selectedItemKeys: Set(items.map(AccessibilityElementKey.init)),
            namesFingerprint: namesFingerprint(itemTexts: itemTexts),
            count: items.count,
            displayNames: itemNamesMayBeShown(bundleIdentifier: bundleIdentifier) ? itemTexts.map { $0.first ?? "" } : nil
        )
    }

    private static func columnLists(of browser: AXUIElement) throws -> [AXUIElement] {
        var lists: [AXUIElement] = []
        func visit(_ element: AXUIElement, depth: Int) throws {
            for child in try elements(element, kAXChildrenAttribute) ?? [] {
                if try string(child, kAXRoleAttribute) == kAXListRole {
                    lists.append(child)
                } else if depth < 3 {
                    try visit(child, depth: depth + 1)
                }
            }
        }
        try visit(browser, depth: 0)
        return lists
    }

    private static func readSelection(container: AXUIElement, attribute: String, bundleIdentifier: String?) throws -> PublishedSelection {
        AXUIElementSetMessagingTimeout(container, messagingTimeoutInSeconds)
        if attribute == kAXBrowserRole {
            let columns = try columnLists(of: container)
            let selectedByColumn = try columns.map { try elements($0, kAXSelectedChildrenAttribute) ?? [] }
            let chosen = lastNonEmptyColumnIndex(selectedCountsByColumn: selectedByColumn.map(\.count))
            return try publishedSelection(container: container, attribute: attribute,
                                          items: chosen.map { selectedByColumn[$0] } ?? [], bundleIdentifier: bundleIdentifier)
        }
        guard let items = try elements(container, attribute) else {
            throw ReadFailure(reason: "the container no longer publishes \(attribute)")
        }
        return try publishedSelection(container: container, attribute: attribute, items: items, bundleIdentifier: bundleIdentifier)
    }

    private static func findSelection(processIdentifier: pid_t, bundleIdentifier: String?) throws -> PublishedSelection {
        let application = AXUIElementCreateApplication(processIdentifier)
        AXUIElementSetMessagingTimeout(application, messagingTimeoutInSeconds)
        // Ask the application, not the window (the window doesn't answer).
        guard let focused = try element(application, kAXFocusedUIElementAttribute) else {
            throw ReadFailure(reason: "the application reports no focused element")
        }
        var chain: [AXUIElement] = [focused]
        while chain.count <= maximumAncestorHops, let parent = try element(chain[chain.count - 1], kAXParentAttribute) {
            chain.append(parent)
        }
        // A browser above wins: its focused column may not hold the acted-on item.
        for candidate in chain {
            if try string(candidate, kAXRoleAttribute) == kAXBrowserRole {
                return try readSelection(container: candidate, attribute: kAXBrowserRole, bundleIdentifier: bundleIdentifier)
            }
        }
        for candidate in chain {
            for attribute in [kAXSelectedRowsAttribute, kAXSelectedChildrenAttribute] {
                if try elements(candidate, attribute) != nil {
                    return try readSelection(container: candidate, attribute: attribute, bundleIdentifier: bundleIdentifier)
                }
            }
        }
        throw ReadFailure(reason: "neither the focused element nor its \(chain.count - 1) ancestors publish a selection")
    }

    private static func timed(_ read: () -> Selection) -> (Selection, Int) {
        let startedAt = Date()
        let selection = read()
        return (selection, Int(Date().timeIntervalSince(startedAt) * 1000))
    }

    /// The selection the action would affect now, found from the app's focus.
    static func liveSelection(_ subject: Subject, bundleIdentifier: String?) -> Selection {
        guard let processIdentifier = subject.processIdentifier else {
            return .unavailable(reason: "no application process to ask")
        }
        do {
            return .published(try findSelection(processIdentifier: processIdentifier, bundleIdentifier: bundleIdentifier))
        } catch let failure as ReadFailure {
            return .unavailable(reason: failure.reason)
        } catch {
            return .unavailable(reason: String(describing: error))
        }
    }

    static func capture(_ subject: Subject, bundleIdentifier: String?,
                        readSelection read: (Subject, String?) -> Selection = liveSelection) -> ActionBinding {
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), messagingTimeoutInSeconds)
        let (selection, milliseconds) = timed { read(subject, bundleIdentifier) }
        return ActionBinding(targetElementKey: subject.targetElement.map(AccessibilityElementKey.init),
                             selection: selection, readMilliseconds: milliseconds)
    }

    /// Re-run the same search from the app's focus at use time. A menu action acts
    /// on whichever window is in front then, so a different container is stale.
    static func recheck(_ approved: ActionBinding, subject: Subject, bundleIdentifier: String?,
                        readSelection read: (Subject, String?) -> Selection = liveSelection) -> (current: ActionBinding, movedPart: String?) {
        let current = capture(subject, bundleIdentifier: bundleIdentifier, readSelection: read)
        return (current, movedPart(approved: approved, currentTargetKey: current.targetElementKey, currentSelection: current.selection))
    }
}
