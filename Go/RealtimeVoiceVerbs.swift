//
//  RealtimeVoiceVerbs.swift
//  Go
//
//  The voice tools after `open_app`: `focus_app`, `find_menu_items` and
//  `press_menu`. The model never writes a menu path: find_menu_items reads the
//  app's menus through the harness, filters them locally (enabled leaves,
//  private items dropped) and offers up to twelve exact paths; press_menu
//  sends one back. Everything acts through `RealtimeOpenAppTool.dispatch`.
//

import AppKit
import CoreServices
import Foundation

nonisolated enum RealtimeVoiceVerbs {
    static let focusAppName = "focus_app"
    static let findMenuItemsName = "find_menu_items"
    static let pressMenuName = "press_menu"
    static let allToolNames: Set<String> = [RealtimeOpenAppTool.name, focusAppName, findMenuItemsName, pressMenuName]

    static let maximumCandidates = 12

    // MARK: Declarations

    private struct Parameter {
        let name: String
        let isList: Bool
        let description: String
    }

    private struct Declaration {
        let name: String
        let description: String
        let parameters: [Parameter]
    }

    private static let declarations = [
        Declaration(name: focusAppName,
                    description: "Brings an app that is already running to the front. Use its name as shown in the Dock, for example \"Finder\".",
                    parameters: [Parameter(name: "name", isList: false, description: "The running app's name, for example \"Finder\".")]),
        Declaration(name: findMenuItemsName,
                    description: "Looks through the menu bar of the app in front for items matching a few words, and returns up to "
                        + "\(maximumCandidates) exact menu paths that can be pressed. The app must be in front; call focus_app first if it is not.",
                    parameters: [
                        Parameter(name: "app", isList: false, description: "The app whose menus to search, for example \"Finder\"."),
                        Parameter(name: "words", isList: false, description: "A few words for the command, for example \"list view\" or \"new window\".")
                    ]),
        Declaration(name: pressMenuName,
                    description: "Presses one menu item of the app in front. The path must be one that find_menu_items returned in this turn, copied exactly.",
                    parameters: [
                        Parameter(name: "app", isList: false, description: "The app in front, for example \"Finder\"."),
                        Parameter(name: "path", isList: true, description: "The menu path exactly as find_menu_items returned it, for example [\"View\", \"as List\"].")
                    ])
    ]

    /// Gemini Live `setup.tools` entry holding every function.
    static var geminiDeclaration: [String: Any] {
        let openApp = (RealtimeOpenAppTool.geminiDeclaration["functionDeclarations"] as? [[String: Any]]) ?? []
        return ["functionDeclarations": openApp + declarations.map { declaration in
            [
                "name": declaration.name, "description": declaration.description,
                "parameters": [
                    "type": "OBJECT",
                    "properties": Dictionary(uniqueKeysWithValues: declaration.parameters.map { parameter in
                        (parameter.name, parameter.isList
                            ? ["type": "ARRAY", "items": ["type": "STRING"], "description": parameter.description] as [String: Any]
                            : ["type": "STRING", "description": parameter.description])
                    }),
                    "required": declaration.parameters.map(\.name)
                ] as [String: Any]
            ] as [String: Any]
        }]
    }

    // MARK: Menu offer

    /// Case-, diacritic- and width-folded words.
    static func foldedTokens(_ text: String) -> [String] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
    }

    /// Filler words that name no menu item.
    static let ignoredQueryWords: Set<String> = ["the", "a", "an", "to", "in", "of", "for", "on", "and", "my", "me", "please", "menu", "menus"]

    /// Equal, or the shorter (3+ letters) begins the longer: "icon" finds "Icons".
    static func tokensMatch(_ first: String, _ second: String) -> Bool {
        if first == second { return true }
        let (shorter, longer) = first.count <= second.count ? (first, second) : (second, first)
        return shorter.count >= 3 && longer.hasPrefix(shorter)
    }

    /// Menus whose items carry personal names (recent files, history, bookmarks,
    /// profiles, the Apple menu's account name). Never offered or pressed.
    static let privateTopLevelMenus: Set<String> = ["apple", "history", "bookmarks", "profiles"]

    static func isPrivateMenuPath(_ path: [String]) -> Bool {
        if let top = path.first, privateTopLevelMenus.contains(foldedTokens(top).joined(separator: " ")) { return true }
        return path.contains { step in quotesSomething(step) || foldedTokens(step).contains { $0.hasPrefix("recent") } }
    }

    /// A quoted step names the selection ("Copy “file” as Pathname"), so the item
    /// is private. A lone ’ is an apostrophe and doesn't count.
    static let quoteMarks: Set<Character> = ["\u{201C}", "\u{201D}", "\u{201E}", "\"", "\u{2018}", "\u{00AB}", "\u{00BB}", "\u{2039}", "\u{203A}",
                                             "\u{300C}", "\u{300D}", "\u{300E}", "\u{300F}"]

    static func quotesSomething(_ label: String) -> Bool {
        label.contains { quoteMarks.contains($0) }
    }

    /// The Window menu ends with one item per open window, named by its title,
    /// so only known commands without a shortcut are offered.
    static let windowMenuCommandsWithoutShortcut: Set<String> = [
        "zoom", "zoom all", "bring all to front", "arrange in front", "merge all windows", "show all tabs",
        "show tab bar", "hide tab bar", "move tab to new window", "name window", "remove window from set"
    ]

    static func isPrivateMenuItem(path: [String], shortcut: String?) -> Bool {
        if isPrivateMenuPath(path) { return true }
        guard path.count == 2, foldedTokens(path[0]) == ["window"], shortcut == nil else { return false }
        return !windowMenuCommandsWithoutShortcut.contains(foldedTokens(path[1]).joined(separator: " "))
    }

    /// Candidates for `words` from a `menus` response: enabled leaves only, private
    /// paths dropped, every step a plausible label.
    static func menuOffer(fromMenusResponse response: [String: Any], words: String) -> RealtimeMenuOffer {
        let items = response["items"] as? [[String: Any]] ?? []
        var enabledItemCount = 0
        var privacyDroppedCount = 0
        var leaves: [RealtimeMenuCandidate] = []
        for item in items where item["enabled"] as? Bool == true {
            enabledItemCount += 1
            guard let path = item["path"] as? [String], !path.isEmpty else { continue }
            if isPrivateMenuItem(path: path, shortcut: item["shortcut"] as? String) { privacyDroppedCount += 1; continue }
            guard item["hasSubmenu"] as? Bool == false,
                  path.allSatisfy({ UntrustedText($0).isPlausibleControlLabel }) else { continue }
            leaves.append(RealtimeMenuCandidate(path: path, shortcut: item["shortcut"] as? String))
        }
        return RealtimeMenuOffer(
            candidates: rankedCandidates(leaves, words: words),
            enabledItemCount: enabledItemCount,
            privacyDroppedCount: privacyDroppedCount,
            listingIncomplete: !((response["listingStopReasons"] as? [String]) ?? []).isEmpty
        )
    }

    /// Ranked by matching words in the path, then in the item's own label, then
    /// menu order. No match means no candidate.
    static func rankedCandidates(_ leaves: [RealtimeMenuCandidate], words: String,
                                 limit: Int = maximumCandidates) -> [RealtimeMenuCandidate] {
        let query = Set(foldedTokens(words)).subtracting(ignoredQueryWords)
        guard !query.isEmpty else { return [] }
        let scored: [(matched: Int, inLabel: Int, index: Int, leaf: RealtimeMenuCandidate)] = leaves.enumerated().compactMap { index, leaf in
            let pathTokens = leaf.path.flatMap(foldedTokens)
            let labelTokens = foldedTokens(leaf.path.last ?? "")
            let matched = query.filter { word in pathTokens.contains { tokensMatch(word, $0) } }.count
            guard matched > 0 else { return nil }
            let inLabel = query.filter { word in labelTokens.contains { tokensMatch(word, $0) } }.count
            return (matched, inLabel, index, leaf)
        }
        return scored.sorted { ($0.matched, $0.inLabel, -$0.index) > ($1.matched, $1.inLabel, -$1.index) }
            .prefix(limit).map(\.leaf)
    }

    // MARK: App identity

    /// Menu tools run only against the app the tool named, resolved to one
    /// installed bundle; the wrong app can have a perfectly matching command.
    static func isAppScopedMenuTool(_ toolName: String) -> Bool {
        toolName == findMenuItemsName || toolName == pressMenuName
    }

    /// A name an app answers to: its file name, or (`isFileName` false) its
    /// shorter menu-bar name ("Code" for Visual Studio Code).
    struct AppName: Equatable {
        let name: String
        let url: URL
        let isFileName: Bool
    }

    enum AppResolution: Equatable {
        case resolved(URL)
        /// Several apps answer to the name: ask, never guess.
        case ambiguous([URL])
        /// None does; `closest` share a word with the name (at most five).
        case notInstalled(closest: [URL])
    }

    /// A full file name is that app. Anything shorter resolves only if exactly one
    /// app answers to it. Whole words, never letters: "code" doesn't find Xcode.
    static func resolveApp(named query: String, among names: [AppName]) -> AppResolution {
        let wanted = foldedTokens(query)
        guard !wanted.isEmpty else { return .notInstalled(closest: []) }
        func unique(_ matches: [AppName]) -> [URL] {
            var seen = Set<String>()
            return matches.map(\.url).filter { seen.insert($0.standardizedFileURL.path).inserted }
        }
        let fullName = unique(names.filter { $0.isFileName && foldedTokens($0.name) == wanted })
        if fullName.count == 1 { return .resolved(fullName[0]) }
        if fullName.count > 1 { return .ambiguous(fullName) }
        let partial = unique(names.filter { name in
            let tokens = foldedTokens(name.name)
            return tokens.count >= wanted.count
                && (0...(tokens.count - wanted.count)).contains { Array(tokens[$0..<($0 + wanted.count)]) == wanted }
        })
        if partial.count == 1 { return .resolved(partial[0]) }
        if partial.count > 1 { return .ambiguous(partial) }
        let closest = unique(names.filter { name in
            let tokens = Set(foldedTokens(name.name))
            return wanted.contains { $0.count >= 3 && tokens.contains($0) }
        })
        return .notInstalled(closest: Array(closest.prefix(5)))
    }

    static func displayName(_ url: URL) -> String {
        url.deletingPathExtension().lastPathComponent
    }

    /// Apps anywhere on the Mac whose name contains `query`, from Spotlight. Apps
    /// inside other apps (helpers) and in the Trash are left out. Blocks: call
    /// off main.
    static func spotlightApps(matching query: String) -> [URL] {
        let name = String(query.filter { !"\"*\\$".contains($0) }.prefix(60)).trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return [] }
        let text = "kMDItemContentType == \"com.apple.application-bundle\" && kMDItemFSName == \"*\(name)*\"cd"
        guard let mdQuery = MDQueryCreate(kCFAllocatorDefault, text as CFString, nil, nil),
              MDQueryExecute(mdQuery, CFOptionFlags(kMDQuerySynchronous.rawValue)) else { return [] }
        var urls: [URL] = []
        for index in 0..<min(MDQueryGetResultCount(mdQuery), 20) {
            guard let raw = MDQueryGetResultAtIndex(mdQuery, index) else { continue }
            let item = Unmanaged<MDItem>.fromOpaque(raw).takeUnretainedValue()
            guard let path = MDItemCopyAttribute(item, kMDItemPath) as? String,
                  !path.contains("/.Trash/"), !path.dropLast(".app".count).contains(".app/") else { continue }
            urls.append(URL(fileURLWithPath: path, isDirectory: true))
        }
        return urls
    }

    /// Every name an installed or running regular app answers to.
    static func installedAppNames() -> [AppName] {
        var names = ApplicationLauncher.searchDirectories.flatMap { directory in
            ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
                .filter { $0.lowercased().hasSuffix(".app") }
                .map { file -> AppName in
                    let url = directory.appendingPathComponent(file, isDirectory: true)
                    return AppName(name: displayName(url), url: url, isFileName: true)
                }
        }
        let installedPaths = Set(names.map { $0.url.standardizedFileURL.path })
        for application in NSWorkspace.shared.runningApplications where application.activationPolicy == .regular {
            guard let name = application.localizedName, let url = application.bundleURL else { continue }
            names.append(AppName(name: name, url: url, isFileName: !installedPaths.contains(url.standardizedFileURL.path)))
        }
        return names
    }

    enum AppIdentity: Equatable {
        case resolved(bundleIdentifier: String, name: String)
        case ambiguous(candidates: [String])
        case notInstalled(closest: [String])
    }

    /// A bundle id names its app outright; anything else goes through
    /// `resolveApp`. Blocks on the file system: call off main.
    static func appIdentity(named query: String) -> AppIdentity {
        let resolution: AppResolution
        if query.contains("."), !query.contains(" "), let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: query) {
            resolution = .resolved(url)
        } else {
            var found = resolveApp(named: query, among: installedAppNames())
            // Not in the usual folders and not running (an app kept in Downloads,
            // on another drive, or a developer build): Spotlight knows where it is.
            if case .notInstalled = found {
                let spotted = spotlightApps(matching: query)
                if !spotted.isEmpty {
                    found = resolveApp(named: query, among: spotted.map { AppName(name: displayName($0), url: $0, isFileName: true) })
                }
            }
            resolution = found
        }
        switch resolution {
        case .resolved(let url):
            guard let bundleIdentifier = Bundle(url: url)?.bundleIdentifier else { return .notInstalled(closest: []) }
            return .resolved(bundleIdentifier: bundleIdentifier, name: displayName(url))
        case .ambiguous(let urls):
            return .ambiguous(candidates: urls.map(displayName))
        case .notInstalled(let closest):
            return .notInstalled(closest: closest.map(displayName))
        }
    }

    /// A name that resolves to exactly one installed app, which is running.
    /// Blocks on the file system: call off main.
    static func isRunning(named query: String) -> Bool {
        guard case .resolved(let bundleIdentifier, _) = appIdentity(named: query) else { return false }
        return !NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).isEmpty
    }

    // MARK: Notch text

    /// "View › as List", each step escaped.
    static func menuPathCaption(_ path: [String]) -> String {
        path.map(RealtimeOpenAppTool.captionName).joined(separator: " \u{203A} ")
    }

    /// The intent line, from the tool's own arguments.
    static func intentTitle(for call: RealtimeToolCall) -> String {
        let app = call.appName.map(RealtimeOpenAppTool.captionName)
        switch call.name {
        case RealtimeOpenAppTool.name:
            return "Opening \(app ?? "an app")\u{2026}"
        case focusAppName:
            return "Switching to \(app ?? "an app")\u{2026}"
        case findMenuItemsName:
            let words = call.words.map(RealtimeOpenAppTool.captionName) ?? "a command"
            return "Looking for \u{2018}\(words)\u{2019} in \(app ?? "the app")\u{2019}s menus\u{2026}"
        case pressMenuName:
            return "\(menuPathCaption(call.path ?? []))\u{2026}"
        default:
            return "Working\u{2026}"
        }
    }

}

nonisolated struct RealtimeMenuCandidate: Equatable, Sendable {
    let path: [String]
    let shortcut: String?

    var jsonObject: [String: Any] { ["path": path, "shortcut": shortcut ?? NSNull()] }
}

nonisolated struct RealtimeMenuOffer: Equatable, Sendable {
    let candidates: [RealtimeMenuCandidate]
    let enabledItemCount: Int
    let privacyDroppedCount: Int
    /// The listing hit a limit, so a missing item may simply be unread.
    let listingIncomplete: Bool
}

/// One tool call in a turn: what was asked, what had been offered, and the dispatch.
nonisolated struct RealtimeToolDecision {
    let call: RealtimeToolCall
    let callUptime: TimeInterval
    let offeredBeforeCall: [RealtimeMenuCandidate]?
    var dispatch: RealtimeToolDispatch?
}
