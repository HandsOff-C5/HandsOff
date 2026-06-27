// VoiceCommandRouter — turns one final transcript into ONE routed command. This is the PARSE +
// RESOLVE half of spoken-command handling: it decides "open Safari" is a launch of com.apple.Safari,
// "type x" injects "x", "press enter" submits, and "move this there" is a point+drag. It owns NO
// actuation — the loop hands the resulting `ParsedCommand` to the gated dispatcher (the integration
// point the director wires; see the port report). Pure/static, so it is fully unit-testable.
//
// Routing (first match wins): "open|launch|start up <app>" → launch; "switch to|focus <app>" →
// focus; "type <text>" → inject into the focused field; "press/hit enter|submit" → submit;
// a deictic with a move verb ("move this there") → point+drag; anything else → none (reported,
// never a wrong action).

import Foundation
#if canImport(AppKit)
import AppKit
#endif

nonisolated enum VoiceCommandRouter {

    /// One routed spoken command.
    enum ParsedCommand: Equatable {
        case launch(appName: String)
        case focus(appName: String)
        case type(text: String)
        case submit
        case move(deictics: [DeicticSpan])
        case none
    }

    /// Parse a final transcript into a command. Explicit command prefixes win over deixis, so
    /// "type this note" types (not point+drag) while "move this there" still routes to point+drag.
    static func parseCommand(_ raw: String) -> ParsedCommand {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .none }
        let lower = text.lowercased()

        for p in ["open ", "launch ", "start up "] where lower.hasPrefix(p) {
            let name = String(text.dropFirst(p.count)).trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { return .launch(appName: name) }
        }
        for p in ["switch to ", "focus on ", "focus ", "bring up "] where lower.hasPrefix(p) {
            let name = String(text.dropFirst(p.count)).trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { return .focus(appName: name) }
        }
        for p in ["type ", "dictate ", "inject "] where lower.hasPrefix(p) {
            let body = String(text.dropFirst(p.count)).trimmingCharacters(in: .whitespaces)
            if !body.isEmpty { return .type(text: body) }
        }
        if ["press enter", "hit enter", "submit", "press return", "hit return"].contains(lower) {
            return .submit
        }
        // Point+drag needs BOTH a move verb AND a deictic ("move this there") — a bare deictic like
        // "it" in "what time is it" must NOT trigger a drag.
        let deictics = extractDeictics(from: text)
        if !deictics.isEmpty, hasMoveVerb(lower) { return .move(deictics: deictics) }
        return .none
    }

    /// Whole-word presence of a move/placement verb (mirrors the engine grammar's move surface forms).
    static func hasMoveVerb(_ lower: String) -> Bool {
        let verbs: Set<String> = ["move", "put", "drag", "send", "throw", "place", "drop"]
        let words = lower.split { !$0.isLetter }.map(String.init)
        return words.contains { verbs.contains($0) }
    }

    /// Extract deictic spans from a transcript (whole-word, token offsets) — the transcript half of
    /// the point+drag check. The presence of any span (with a move verb) is what routes to a drag.
    static func extractDeictics(from transcript: String) -> [DeicticSpan] {
        let deicticWords: Set<String> = ["this", "that", "there", "here", "it"]
        let lower = transcript.lowercased()
        var spans: [DeicticSpan] = []
        var index = 0
        for token in lower.split(separator: " ", omittingEmptySubsequences: true) {
            let word = token.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
            if deicticWords.contains(word) {
                spans.append(DeicticSpan(text: word, start: index, end: index + 1))
            }
            index += 1
        }
        return spans
    }

    // MARK: - App name → bundle id

    /// Common apps by spoken name → bundle id (fast path, no deprecated lookup). Lowercased keys.
    static let knownApps: [String: String] = [
        "safari": "com.apple.Safari", "notes": "com.apple.Notes", "mail": "com.apple.mail",
        "messages": "com.apple.MobileSMS", "calendar": "com.apple.iCal", "finder": "com.apple.finder",
        "terminal": "com.apple.Terminal", "music": "com.apple.Music", "photos": "com.apple.Photos",
        "maps": "com.apple.Maps", "reminders": "com.apple.reminders", "preview": "com.apple.Preview",
        "calculator": "com.apple.calculator", "textedit": "com.apple.TextEdit",
        "system settings": "com.apple.systempreferences", "system preferences": "com.apple.systempreferences",
        "settings": "com.apple.systempreferences", "app store": "com.apple.AppStore",
        "chrome": "com.google.Chrome", "google chrome": "com.google.Chrome",
        "slack": "com.tinyspeck.slackmacgap", "spotify": "com.spotify.client",
        "code": "com.microsoft.VSCode", "vs code": "com.microsoft.VSCode",
        "visual studio code": "com.microsoft.VSCode", "xcode": "com.apple.dt.Xcode",
        "zoom": "us.zoom.xos", "discord": "com.hnc.Discord", "notion": "notion.id",
    ]

    /// Resolve a spoken app name to a bundle id. STT mis-hears names ("saferie" for "Safari"), so the
    /// match is FUZZY: exact known map → exact LaunchServices lookup → nearest known app within an
    /// edit-distance threshold. nil → genuinely not found (the caller reports it, never guesses wrong).
    static func resolveBundleId(forAppNamed name: String) -> String? {
        let key = name.lowercased().trimmingCharacters(in: .whitespaces)
        if key.isEmpty { return nil }
        if let known = knownApps[key] { return known }
        #if canImport(AppKit)
        if let path = NSWorkspace.shared.fullPath(forApplication: name),
           let bundleId = Bundle(url: URL(fileURLWithPath: path))?.bundleIdentifier {
            return bundleId
        }
        #endif
        // FUZZY: nearest known-app name within ~⅓ of its length (so "saferie"→"safari", dist 2 ≤ 2).
        var best: (key: String, dist: Int)?
        for candidate in knownApps.keys {
            let d = EditDistance.levenshtein(key, candidate)
            if best == nil || d < best!.dist { best = (candidate, d) }
        }
        if let best, best.dist <= max(2, best.key.count / 3) {
            return knownApps[best.key]
        }
        return nil
    }
}
