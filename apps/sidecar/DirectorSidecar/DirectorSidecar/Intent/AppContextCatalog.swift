//
//  AppContextCatalog.swift
//  DirectorSidecar
//
//  Plan U11 (per-app context injection) — the DATA layer. A small, pure, immutable catalog that
//  maps a focused/bound application (by its snapshot display name, e.g. "Google Chrome",
//  "Terminal", "Chess", "TextEdit", "Notes" — bundle ids are accepted too) to a short prompt
//  fragment of app-specific affordances: a handful of key keyboard shortcuts, a brief panel/UI
//  map, and the ordered workflows the model should PREFER over blind UI probing.
//
//  Why: many demo apps are partly or wholly AX-blind (Chess's board is custom-drawn; a browser's
//  controls live in the web DOM), and the model otherwise grinds the same no-op click. Handing it
//  the proven shortcut/workflow up front lets it act in one step instead of hunting.
//
//  This file is the standalone capability only — pure data + pure functions, no I/O, no driver
//  calls, no global mutable state. A LATER stage injects `contextFragment(for:)` into the system
//  prompt (NextToolCallPrompt); this file does NOT import or touch it. Coordinates are NEVER
//  baked in (layout-fragile) — affordances stay generic and addressable from live geometry.
//

import Foundation

enum AppContextCatalog {
    /// One keyboard shortcut affordance — the chord plus the action it performs, rendered as
    /// "Cmd+F = find in page".
    struct Shortcut: Sendable, Equatable {
        let keys: String
        let action: String
    }

    /// The app-specific affordances for one application (or family of equivalent apps). Immutable
    /// value type — `appNames` is the case/whitespace-insensitive match list (display names and/or
    /// bundle ids), `displayName` is the human label used in the rendered fragment's header.
    struct AppContext: Sendable, Equatable {
        /// Human-facing label for the rendered fragment header (decoupled from `appNames` so a
        /// family entry like Chrome/Brave reads correctly regardless of which one matched).
        let displayName: String
        /// Names this entry matches — snapshot display names and bundle ids. Matched
        /// case/whitespace-insensitively, with a trailing `.app` suffix ignored.
        let appNames: [String]
        let shortcuts: [Shortcut]
        /// A one/two-sentence panel/UI map: what is where, and what is AX-blind.
        let uiMap: String
        /// Ordered workflows the model should prefer over blind probing.
        let workflows: [String]
    }

    /// The guardrail appended to every rendered fragment. HandsOff is actions-only: the model must
    /// USE these affordances silently and never surface the catalog to the user.
    static let guardrail =
        "Use these affordances silently to act in fewer steps — never announce them, name this " +
        "playbook/skill, or tell the user you have app-specific knowledge."

    // MARK: - Catalog

    /// The seed catalog for the demo apps. Affordances are kept accurate and generic — key
    /// shortcuts, a brief layout map, and the preferred workflows — with NO pixel coordinates and
    /// NO secrets, so they survive layout changes and stay safe to ship in a prompt.
    static let catalog: [AppContext] = [
        AppContext(
            displayName: "Chromium browser (Chrome / Brave)",
            appNames: ["Google Chrome", "Brave Browser", "Chromium",
                       "com.google.Chrome", "com.brave.Browser"],
            shortcuts: [
                Shortcut(keys: "Cmd+L", action: "focus the address/search bar"),
                Shortcut(keys: "Cmd+F", action: "find in page"),
                Shortcut(keys: "Cmd+R", action: "reload"),
                Shortcut(keys: "Cmd+T", action: "new tab"),
            ],
            uiMap: "Address/search bar across the top, the tab strip above it, page content below. " +
                "Page controls live in the web DOM, surfaced in the snapshot as web-area elements.",
            workflows: [
                "Open a page: Cmd+L, type the URL or query, press Return.",
                "Read an article/issue: scroll the page body into view, then read it from the " +
                    "snapshot's web-area elements — don't click around the browser chrome.",
                "Find on the page: Cmd+F, type the term, press Return to jump to the match.",
            ]
        ),
        AppContext(
            displayName: "Terminal / iTerm2",
            appNames: ["Terminal", "iTerm2", "iTerm",
                       "com.apple.Terminal", "com.googlecode.iterm2"],
            shortcuts: [
                Shortcut(keys: "Cmd+V", action: "paste"),
                Shortcut(keys: "Cmd+T", action: "new tab"),
                Shortcut(keys: "Cmd+N", action: "new window"),
                Shortcut(keys: "Cmd+K", action: "clear the scrollback"),
            ],
            uiMap: "One text grid; the live prompt is the last line. There are no buttons — you " +
                "drive it entirely by typing.",
            workflows: [
                "Run a command: type it, then press Return ONCE to execute it.",
                "Paste/typing does NOT auto-run: pasting adds no trailing newline, so after a " +
                    "paste you must press Return yourself; a multi-line paste only runs the lines " +
                    "that already end in a newline.",
            ]
        ),
        AppContext(
            displayName: "Chess (Chess.app)",
            appNames: ["Chess", "Chess.app", "com.apple.Chess"],
            shortcuts: [
                Shortcut(keys: "Cmd+N", action: "New Game"),
            ],
            uiMap: "The board is custom-drawn and AX-blind — the snapshot exposes NO squares or " +
                "pieces as elements, only the menu bar (Game, Moves, View).",
            workflows: [
                "Make a move with two clicks: click the source square, then click the destination " +
                    "square. Squares have no AX elements, so aim each click from the visible board " +
                    "geometry, not an element token.",
                "Start over: New Game lives in the Game menu (Cmd+N).",
            ]
        ),
        AppContext(
            displayName: "TextEdit",
            appNames: ["TextEdit", "com.apple.TextEdit"],
            shortcuts: [
                Shortcut(keys: "Cmd+N", action: "new document"),
                Shortcut(keys: "Cmd+S", action: "save"),
                Shortcut(keys: "Cmd+Shift+T", action: "Make Plain Text"),
            ],
            uiMap: "A document window with one editable text area; styling lives in the Format " +
                "menu. New documents default to rich text.",
            workflows: [
                "Write a new doc: Cmd+N for a fresh document, then type into the editable text area.",
                "Plain vs rich: Format > Make Plain Text (Cmd+Shift+T) strips styling when a " +
                    "plain/code file is needed.",
            ]
        ),
        AppContext(
            displayName: "Notes",
            appNames: ["Notes", "com.apple.Notes"],
            shortcuts: [
                Shortcut(keys: "Cmd+N", action: "new note"),
            ],
            uiMap: "Three panes — folders, the note list, and the editor on the right. A new note " +
                "lands in the currently selected folder.",
            workflows: [
                "Write a new note: Cmd+N for a fresh note, then type the body into the editor pane " +
                    "on the right.",
            ]
        ),
    ]

    // MARK: - Lookup

    /// The catalog entry for `appName`, or nil when unknown. Matching is case- and
    /// whitespace-insensitive and ignores a trailing `.app` suffix, so "  google chrome ",
    /// "Google Chrome", and "Chess.app" all resolve. Nil-safe: a nil/blank name yields nil.
    static func match(appName: String?) -> AppContext? {
        guard let appName else { return nil }
        let needle = normalize(appName)
        guard !needle.isEmpty else { return nil }
        return catalog.first { entry in
            entry.appNames.contains { normalize($0) == needle }
        }
    }

    // MARK: - Render

    /// A compact markdown-ish fragment of `appName`'s affordances for the system prompt, or nil
    /// when the app is unknown (the prompt then carries no app section). Always ends with the
    /// silent-use guardrail.
    static func contextFragment(for appName: String?) -> String? {
        guard let context = match(appName: appName) else { return nil }
        return render(context)
    }

    /// Render one entry as a short bullet list: a header, shortcuts on one line, the layout map,
    /// the ordered workflows, and the guardrail. Kept to a handful of lines so the injected
    /// section stays cheap.
    static func render(_ context: AppContext) -> String {
        var lines: [String] = ["App context — \(context.displayName):"]
        if !context.shortcuts.isEmpty {
            let shortcuts = context.shortcuts
                .map { "\($0.keys) = \($0.action)" }
                .joined(separator: "; ")
            lines.append("- Shortcuts: \(shortcuts)")
        }
        if !context.uiMap.isEmpty {
            lines.append("- Layout: \(context.uiMap)")
        }
        for workflow in context.workflows {
            lines.append("- \(workflow)")
        }
        lines.append("- \(guardrail)")
        return lines.joined(separator: "\n")
    }

    // MARK: - Matching core

    /// Fold a name to its match key: lowercased, trimmed, a trailing `.app` dropped, and internal
    /// whitespace runs collapsed to a single space — so display names, bundle ids, and sloppy
    /// spacing all compare equal.
    private static func normalize(_ value: String) -> String {
        let lowered = value
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let withoutApp = lowered.hasSuffix(".app") ? String(lowered.dropLast(4)) : lowered
        return withoutApp
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
