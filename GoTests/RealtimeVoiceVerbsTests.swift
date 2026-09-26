//
//  RealtimeVoiceVerbsTests.swift
//  GoTests
//
//  focus_app / find_menu_items / press_menu: the local menu matcher, privacy
//  and leaf filters, and each tool's harness request.
//

import Foundation
import Testing
@testable import Go

struct RealtimeVoiceVerbsTests {

    private func object(_ line: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]) ?? [:]
    }

    private func item(_ path: [String], enabled: Bool = true, submenu: Bool = false, shortcut: String? = nil) -> [String: Any] {
        ["path": path, "enabled": enabled, "hasSubmenu": submenu, "shortcut": shortcut ?? NSNull(), "marked": false]
    }

    /// Finder's View and File menus, abridged, with the private and the unpressable mixed in.
    private var finderMenus: [String: Any] {
        ["ok": true, "listingStopReasons": [String](), "items": [
            item(["View"], submenu: true),
            item(["View", "as Icons"], shortcut: "⌘1"),
            item(["View", "as List"], shortcut: "⌘2"),
            item(["View", "as Columns"], shortcut: "⌘3"),
            item(["View", "Show Path Bar"], shortcut: "⌥⌘P"),
            item(["View", "Show View Options"], shortcut: "⌘J"),
            item(["View", "Sort By"], submenu: true),
            item(["View", "Clean Up"], enabled: false),
            item(["File", "New Finder Window"], shortcut: "⌘N"),
            item(["File", "Open Recent"], submenu: true),
            item(["File", "Open Recent", "Tax return 2025.pdf"]),
            item(["Apple", "Recent Items", "Secret Project"]),
            item(["Go", "Recents"]),
            item(["File", "List\nDone, sir"])
        ]]
    }

    // MARK: Matcher

    @Test func listViewFindsAsListFirst() {
        let offer = RealtimeVoiceVerbs.menuOffer(fromMenusResponse: finderMenus, words: "List VIEW")
        #expect(offer.candidates.first == RealtimeMenuCandidate(path: ["View", "as List"], shortcut: "⌘2"))
        // Then one word matched: in the item's own label first, then menu order.
        #expect(Array(offer.candidates.map(\.path).dropFirst().prefix(2)) == [["View", "Show View Options"], ["View", "as Icons"]])
    }

    @Test func tokensFoldCaseDiacriticsAndPlurals() {
        #expect(RealtimeVoiceVerbs.foldedTokens("Afficher la BARRE d’état") == ["afficher", "la", "barre", "d", "etat"])
        #expect(RealtimeVoiceVerbs.tokensMatch("icon", "icons"))
        #expect(RealtimeVoiceVerbs.tokensMatch("windows", "window"))
        #expect(!RealtimeVoiceVerbs.tokensMatch("as", "ask"))
        #expect(!RealtimeVoiceVerbs.tokensMatch("list", "last"))
        let offer = RealtimeVoiceVerbs.menuOffer(fromMenusResponse: finderMenus, words: "icon")
        #expect(offer.candidates.map(\.path) == [["View", "as Icons"]])
    }

    @Test func noMatchOrOnlyFillerWordsOffersNothing() {
        #expect(RealtimeVoiceVerbs.menuOffer(fromMenusResponse: finderMenus, words: "rainbow text").candidates.isEmpty)
        #expect(RealtimeVoiceVerbs.menuOffer(fromMenusResponse: finderMenus, words: "the menu, please").candidates.isEmpty)
    }

    @Test func atMostTwelveCandidates() {
        let many = (1...30).map { RealtimeMenuCandidate(path: ["Window", "Window \($0)"], shortcut: nil) }
        let ranked = RealtimeVoiceVerbs.rankedCandidates(many, words: "window")
        #expect(ranked.count == RealtimeVoiceVerbs.maximumCandidates)
        #expect(ranked.first?.path == ["Window", "Window 1"])
    }

    // MARK: Filters

    @Test func recentPathsAreDroppedCountedAndNeverOffered() {
        let offer = RealtimeVoiceVerbs.menuOffer(fromMenusResponse: finderMenus, words: "recent tax secret project recents open")
        #expect(offer.candidates.isEmpty)
        // Open Recent (parent), its file, Recent Items' child and Go > Recents.
        #expect(offer.privacyDroppedCount == 4)
        #expect(RealtimeVoiceVerbs.isPrivateMenuPath(["File", "Open Recent", "x"]))
        #expect(RealtimeVoiceVerbs.isPrivateMenuPath(["Go", "RÉCENTS"]))
        #expect(!RealtimeVoiceVerbs.isPrivateMenuPath(["View", "as List"]))
    }

    /// Chrome's first run offered History and Window items: page titles live there.
    @Test func historyBookmarksProfilesAppleAndWindowTitlesArePrivate() {
        #expect(RealtimeVoiceVerbs.isPrivateMenuPath(["History", "4 Tabs", "Restore window"]))
        #expect(RealtimeVoiceVerbs.isPrivateMenuPath(["Bookmarks", "Bank"]))
        #expect(RealtimeVoiceVerbs.isPrivateMenuPath(["Profiles", "Someone"]))
        #expect(RealtimeVoiceVerbs.isPrivateMenuPath(["Apple", "Log Out Someone…"]))
        // A window's title (no shortcut) is private; a command is not.
        #expect(RealtimeVoiceVerbs.isPrivateMenuItem(path: ["Window", "Inbox (3) - Gmail"], shortcut: nil))
        #expect(!RealtimeVoiceVerbs.isPrivateMenuItem(path: ["Window", "Zoom All"], shortcut: nil))
        #expect(!RealtimeVoiceVerbs.isPrivateMenuItem(path: ["Window", "Name Window…"], shortcut: nil))
        #expect(!RealtimeVoiceVerbs.isPrivateMenuItem(path: ["Window", "Minimise"], shortcut: "⌘M"))
        #expect(!RealtimeVoiceVerbs.isPrivateMenuItem(path: ["Window", "Move & Resize", "Left"], shortcut: nil))
        let menus: [String: Any] = ["ok": true, "items": [
            item(["Window", "Inbox (3) - Gmail"]), item(["Window", "Zoom All"]), item(["History", "Show Full History"], shortcut: "⌘Y")
        ]]
        let offer = RealtimeVoiceVerbs.menuOffer(fromMenusResponse: menus, words: "inbox gmail zoom history")
        #expect(offer.candidates.map(\.path) == [["Window", "Zoom All"]])
        #expect(offer.privacyDroppedCount == 2)
    }

    /// Finder quotes the selection inside the command; each quote style a
    /// localisation uses is private, the apostrophe is not.
    @Test func anItemQuotingSomethingIsPrivateInEveryQuoteStyle() {
        for label in ["Copy \u{201C}Tax return.pdf\u{201D} as Pathname", "Open \"Tax return.pdf\"", "Compress \u{2018}Tax\u{2019}",
                      "Renommer \u{00AB} Imp\u{00F4}ts \u{00BB}\u{2026}", "\u{201E}Steuer\u{201C} komprimieren", "Get Info on \u{2039}x\u{203A}"] {
            #expect(RealtimeVoiceVerbs.isPrivateMenuPath(["File", label]), "\(label)")
            #expect(RealtimeVoiceVerbs.isPrivateMenuItem(path: ["File", label], shortcut: "\u{2318}C"), "\(label)")
        }
        #expect(!RealtimeVoiceVerbs.isPrivateMenuPath(["File", "Don\u{2019}t Save"]))
        #expect(!RealtimeVoiceVerbs.isPrivateMenuPath(["Edit", "Copy"]))
        let menus: [String: Any] = ["ok": true, "items": [
            item(["Edit", "Copy \u{201C}Tax return.pdf\u{201D} as Pathname"], shortcut: "\u{2325}\u{2318}C"),
            item(["File", "Open \u{201C}Tax return.pdf\u{201D}"]),
            item(["Edit", "Copy"], shortcut: "\u{2318}C")
        ]]
        let offer = RealtimeVoiceVerbs.menuOffer(fromMenusResponse: menus, words: "copy open tax pathname")
        #expect(offer.candidates.map(\.path) == [["Edit", "Copy"]])
        #expect(offer.privacyDroppedCount == 2)
    }

    /// Created 0600 by open(2), never created 0644 and narrowed after; an older
    /// 0644 file is narrowed on its next append.
    @Test func measurementLogsAreOwnerOnlyFromCreation() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        func mode(_ url: URL) -> Int? { (try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]) as? Int }
        let fresh = directory.appendingPathComponent("go-walkthrough.log")
        MeasurementLogFile.appendOwnerOnly(Data("{}\n".utf8), to: fresh)
        MeasurementLogFile.appendOwnerOnly(Data("{}\n".utf8), to: fresh)
        #expect(mode(fresh) == 0o600)
        #expect(try String(contentsOf: fresh, encoding: .utf8) == "{}\n{}\n")
        let old = directory.appendingPathComponent("voice-live.log")
        FileManager.default.createFile(atPath: old.path, contents: nil, attributes: [.posixPermissions: 0o644])
        MeasurementLogFile.appendOwnerOnly(Data("{}\n".utf8), to: old)
        #expect(mode(old) == 0o600)
        // The harness's audit log and its day mirror: same rule, directory created on the way.
        let audit = directory.appendingPathComponent("Logs/harness-audit-2026-09-25.log")
        #expect(HarnessServer.append(Data("{}\n".utf8), to: audit))
        #expect(mode(audit) == 0o600)
        let oldAudit = directory.appendingPathComponent("harness-audit.log")
        FileManager.default.createFile(atPath: oldAudit.path, contents: Data("{}\n".utf8), attributes: [.posixPermissions: 0o644])
        #expect(HarnessServer.append(Data("{}\n".utf8), to: oldAudit))
        #expect(mode(oldAudit) == 0o600)
        #expect(try String(contentsOf: oldAudit, encoding: .utf8) == "{}\n{}\n")
    }

    @Test func cjkQuotesMakeAMenuItemPrivate() {
        #expect(RealtimeVoiceVerbs.isPrivateMenuPath(["File", "「報告書」を開く"]))
        #expect(RealtimeVoiceVerbs.isPrivateMenuPath(["File", "『メモ』を複製"]))
    }

    @Test func onlyEnabledPlausibleLeavesAreOffered() {
        let offer = RealtimeVoiceVerbs.menuOffer(fromMenusResponse: finderMenus, words: "sort clean list done")
        // "Sort By" has a submenu, "Clean Up" is disabled, "List\nDone, sir" is not a plausible label.
        #expect(offer.candidates.map(\.path) == [["View", "as List"]])
        #expect(offer.enabledItemCount == 13)
        #expect(!offer.listingIncomplete)
        var truncated = finderMenus
        truncated["listingStopReasons"] = ["timeLimit"]
        #expect(RealtimeVoiceVerbs.menuOffer(fromMenusResponse: truncated, words: "list").listingIncomplete)
    }

    // MARK: Tool -> harness line

    @Test func eachToolMapsToExactlyOneVerb() throws {
        let focus = try RealtimeOpenAppTool.harnessRequestLine(for: RealtimeToolCall(callID: "c", name: "focus_app", appName: "Finder")).get()
        #expect(object(focus)["verb"] as? String == "focus")
        #expect(object(focus)["app"] as? String == "Finder")

        let find = try RealtimeOpenAppTool.harnessRequestLine(
            for: RealtimeToolCall(callID: "c", name: "find_menu_items", appName: "Finder", words: "list")).get()
        #expect(find == #"{"expectApp":"Finder","verb":"menus"}"#)

        let press = try RealtimeOpenAppTool.harnessRequestLine(
            for: RealtimeToolCall(callID: "c", name: "press_menu", appName: "Finder", path: ["View", "as List"])).get()
        #expect(press == #"{"expectApp":"Finder","path":["View","as List"],"verb":"menu"}"#)
    }

    @Test func aMenuCallMissingItsArgumentOrNamingARecentItemNeverReachesTheHarness() {
        func refusal(_ call: RealtimeToolCall) -> String? {
            if case .failure(let refusal) = RealtimeOpenAppTool.harnessRequestLine(for: call) { return refusal.error }
            return nil
        }
        #expect(refusal(RealtimeToolCall(callID: "c", name: "find_menu_items", appName: "Finder")) == "missingWords")
        #expect(refusal(RealtimeToolCall(callID: "c", name: "press_menu", appName: "Finder", path: [])) == "missingMenuPath")
        #expect(refusal(RealtimeToolCall(callID: "c", name: "press_menu", appName: nil, path: ["View", "as List"])) == "missingAppName")
        #expect(refusal(RealtimeToolCall(callID: "c", name: "press_menu", appName: "Finder",
                                         path: ["File", "Open Recent", "Tax return 2025.pdf"])) == "privateMenuItem")
        // An item that quotes the selection is refused the same way, before the harness.
        #expect(refusal(RealtimeToolCall(callID: "c", name: "press_menu", appName: "Finder",
                                         path: ["Edit", "Copy \u{201C}Tax return.pdf\u{201D} as Pathname"])) == "privateMenuItem")
    }

    @Test func argumentsParseForEveryTool() throws {
        let gemini: [String: Any] = ["toolCall": ["functionCalls": [
            ["id": "p1", "name": "press_menu", "args": ["app": " Finder ", "path": ["View", "as List"]]],
            ["id": "g1", "name": "find_menu_items", "args": ["app": "Finder", "words": ["list", "view"]]]
        ]]]
        #expect(RealtimeOpenAppTool.parseGemini(gemini) == [
            RealtimeToolCall(callID: "p1", name: "press_menu", appName: "Finder", path: ["View", "as List"]),
            RealtimeToolCall(callID: "g1", name: "find_menu_items", appName: "Finder", words: "list view")
        ])
    }

    @Test func aFindHandsTheModelOnlyTheFilteredCandidates() async {
        let listing = String(decoding: try! JSONSerialization.data(withJSONObject: finderMenus), as: UTF8.self)
        let call = RealtimeToolCall(callID: "c", name: "find_menu_items", appName: "Finder", words: "list view")
        let dispatch = await RealtimeOpenAppTool.dispatch(call, answer: { _ in listing })
        #expect(dispatch.harnessConfirmed)
        #expect(dispatch.harnessResponse?["items"] == nil)
        let candidates = dispatch.result["candidates"] as? [[String: Any]] ?? []
        #expect(candidates.first?["path"] as? [String] == ["View", "as List"])
        #expect(!String(describing: dispatch.result).contains("Tax return"))
        #expect(dispatch.menuOffer?.privacyDroppedCount == 4)
    }

    @Test func everyToolIsDeclared() {
        let geminiNames = (RealtimeVoiceVerbs.geminiDeclaration["functionDeclarations"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
        #expect(Set(geminiNames) == RealtimeVoiceVerbs.allToolNames)
    }

    // MARK: App identity

    private func app(_ path: String, _ name: String? = nil, file: Bool = true) -> RealtimeVoiceVerbs.AppName {
        let url = URL(fileURLWithPath: path, isDirectory: true)
        return RealtimeVoiceVerbs.AppName(name: name ?? url.deletingPathExtension().lastPathComponent, url: url, isFileName: file)
    }

    /// A typical Mac: VS Code shows as "Code" while running, a URL handler sits in
    /// ~/Applications, and Finder is found only as a running app.
    private var installed: [RealtimeVoiceVerbs.AppName] {
        [app("/Applications/Cursor.app"), app("/Applications/Visual Studio Code.app"), app("/Applications/Google Chrome.app"),
         app("/Applications/Xcode.app"), app("/Users/o/Applications/Claude Code URL Handler.app"),
         app("/System/Applications/TextEdit.app"),
         app("/Applications/Visual Studio Code.app", "Code", file: false),
         app("/Applications/Google Chrome.app", "Google Chrome", file: false),
         app("/System/Library/CoreServices/Finder.app", "Finder", file: true)]
    }

    @Test func aNamedAppResolvesToOneBundleOrIsAskedAbout() {
        func resolved(_ query: String) -> String? {
            if case .resolved(let url) = RealtimeVoiceVerbs.resolveApp(named: query, among: installed) { return RealtimeVoiceVerbs.displayName(url) }
            return nil
        }
        #expect(resolved("Cursor") == "Cursor")
        #expect(resolved("visual studio code") == "Visual Studio Code")
        #expect(resolved("Chrome") == "Google Chrome")
        #expect(resolved("Finder") == "Finder")
        #expect(resolved("Xcode") == "Xcode")
        #expect(resolved("TextEdit") == "TextEdit")
        // "code": VS Code's menu-bar name and a word of another app's name. Never Xcode.
        #expect(RealtimeVoiceVerbs.resolveApp(named: "code", among: installed) == .ambiguous([
            URL(fileURLWithPath: "/Applications/Visual Studio Code.app", isDirectory: true),
            URL(fileURLWithPath: "/Users/o/Applications/Claude Code URL Handler.app", isDirectory: true)
        ]))
        #expect(RealtimeVoiceVerbs.resolveApp(named: "Kasa", among: installed) == .notInstalled(closest: []))
        guard case .notInstalled(let closest) = RealtimeVoiceVerbs.resolveApp(named: "VS Code", among: installed) else {
            Issue.record("VS Code is no app's name here"); return
        }
        #expect(closest.map(RealtimeVoiceVerbs.displayName) == ["Visual Studio Code", "Claude Code URL Handler"])
        #expect(RealtimeVoiceVerbs.resolveApp(named: "  ", among: installed) == .notInstalled(closest: []))
    }

    @Test func anAmbiguousOrMissingAppIsReportedWithDisplayNamesOnly() {
        let ambiguous = RealtimeOpenAppTool.appCheckRefusal(.ambiguous(candidates: ["Visual Studio Code", "Claude Code URL Handler"]), named: "code")
        #expect(ambiguous["ok"] as? Bool == false)
        #expect(ambiguous["error"] as? String == "ambiguousApp")
        #expect(ambiguous["candidates"] as? [String] == ["Visual Studio Code", "Claude Code URL Handler"])
        let missing = RealtimeOpenAppTool.appCheckRefusal(.notInstalled(closest: []), named: "Kasa")
        #expect(missing["error"] as? String == "appNotInstalled")
        #expect(RealtimeOpenAppTool.appCheck(.ambiguous(candidates: []), named: "code", harnessResponse: nil)["outcome"] as? String == "ambiguousApp")
    }

    /// Finder is found on every Mac this runs on; the harness is a stub that
    /// answers as it does when VS Code is in front.
    @Test func aMenuCallAgainstADifferentFrontmostAppSaysSoAndNamesBoth() async {
        let sent = LockedLines()
        let frontmostChanged = #"{"ok":false,"error":"frontmostChanged","expectedApp":"com.apple.finder","actualApp":{"name":"Code","bundleIdentifier":"com.microsoft.VSCode"}}"#
        let call = RealtimeToolCall(callID: "c", name: "press_menu", appName: "Finder", path: ["File", "New Finder Window"])
        let dispatch = await RealtimeOpenAppTool.dispatch(call, answer: { line in sent.append(line); return frontmostChanged })
        #expect(sent.lines.count == 1)
        #expect(object(sent.lines.first ?? "")["expectApp"] as? String == "com.apple.finder")
        #expect(!dispatch.harnessConfirmed)
        #expect(dispatch.result["error"] as? String == "appMismatch")
        #expect(dispatch.result["named"] as? String == "Finder")
        #expect(dispatch.result["frontmost"] as? String == "Code")
        #expect(dispatch.appCheck?["outcome"] as? String == "appMismatch")
        #expect(dispatch.appCheck?["resolvedBundleId"] as? String == "com.apple.finder")
        #expect(dispatch.appCheck?["frontmostBundleId"] as? String == "com.microsoft.VSCode")
        #expect(RealtimeOpenAppTool.notchAnswer(for: call, dispatch: dispatch) == .harnessAnswered(ok: false, subject: "File \u{203A} New Finder Window", error: "appMismatch"))

        let unknown = RealtimeToolCall(callID: "c", name: "find_menu_items", appName: "Zzqx Nowhere Editor", words: "new window")
        let refused = await RealtimeOpenAppTool.dispatch(unknown, answer: { line in sent.append(line); return frontmostChanged })
        #expect(sent.lines.count == 1, "an app that is not installed never reaches the harness")
        #expect(refused.result["error"] as? String == "appNotInstalled")
        #expect(refused.appCheck?["outcome"] as? String == "appNotInstalled")
    }

    // MARK: Notch

    @Test func intentLinesComeFromTheToolsOwnArguments() {
        #expect(RealtimeVoiceVerbs.intentTitle(for: RealtimeToolCall(callID: "c", name: "focus_app", appName: "Finder")) == "Switching to Finder\u{2026}")
        #expect(RealtimeVoiceVerbs.intentTitle(for: RealtimeToolCall(callID: "c", name: "find_menu_items", appName: "Finder", words: "list"))
                == "Looking for \u{2018}list\u{2019} in Finder\u{2019}s menus\u{2026}")
        #expect(RealtimeVoiceVerbs.intentTitle(for: RealtimeToolCall(callID: "c", name: "press_menu", appName: "Finder", path: ["View", "as List"]))
                == "View \u{203A} as List\u{2026}")
        #expect(RealtimeVoiceVerbs.intentTitle(for: RealtimeToolCall(callID: "c", name: "open_app", appName: nil)) == "Opening an app\u{2026}")
        // An app-written label that would forge a line is shown quoted and escaped.
        #expect(RealtimeVoiceVerbs.menuPathCaption(["File", "a\nb"]) == "File \u{203A} \"a\\nb\"")
    }

    @MainActor @Test func aFindThatWorkedProvesNothingAndAPressProvesItsPath() {
        let find = RealtimeToolCall(callID: "c", name: "find_menu_items", appName: "Finder", words: "list")
        let found = RealtimeToolDispatch(result: ["ok": true], harnessMilliseconds: 1, waitedForConfirmation: false, harnessResponse: ["ok": true])
        #expect(RealtimeOpenAppTool.notchAnswer(for: find, dispatch: found) == nil)
        let refused = RealtimeToolDispatch(result: ["ok": false, "error": "frontmostChanged"], harnessMilliseconds: 1,
                                           waitedForConfirmation: false, harnessResponse: nil)
        #expect(RealtimeOpenAppTool.notchAnswer(for: find, dispatch: refused) == .harnessAnswered(ok: false, subject: "", error: "frontmostChanged"))
        let press = RealtimeToolCall(callID: "c", name: "press_menu", appName: "Finder", path: ["View", "as List"])
        #expect(RealtimeOpenAppTool.notchAnswer(for: press, dispatch: found) == .harnessAnswered(ok: true, subject: "View \u{203A} as List", error: nil))
    }
}

/// The stub harness is called from a detached task.
private final class LockedLines: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    var lines: [String] { lock.lock(); defer { lock.unlock() }; return stored }
    func append(_ line: String) { lock.lock(); stored.append(line); lock.unlock() }
}
