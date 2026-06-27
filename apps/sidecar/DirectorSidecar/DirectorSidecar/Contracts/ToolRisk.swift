//
//  ToolRisk.swift
//  DirectorSidecar
//
//  Port of @handsoff/contracts tool-risk.ts — the static per-tool risk classification
//  (`TOOL_RISK`, `COMMIT_PATTERNS`, the click/key/page refinements, `riskForToolCall`,
//  `riskForToolName`). This is the dependency the LLM next-tool-call resolver (Track C)
//  keys the DISPLAY intent's provisional risk off of, and the same gate the dispatch
//  step (PORTING.md § Porting Order 3) will reuse — it lives in the shared `Contracts`
//  namespace for exactly the reason the TS module does (both the loop's reasoning side
//  and the executor's gate side must key risk off the tool name).
//
//  CONTRACT (do not drift — ADR 0005): risk is DERIVED locally from the tool (+ target),
//  NEVER trusted from the model. The four tiers + approval policy live in
//  RiskLevel+Policy.swift; this maps each driver tool to one of them and refines the
//  context-dependent tools (click / press_key / hotkey / page) from a target inspection.
//

import Foundation

extension Contracts {
    /// Per-tool risk classification + the per-call gate. Mirrors tool-risk.ts exactly so the
    /// Swift loop and a future Swift executor share one risk vocabulary.
    enum ToolRisk {
        /// `TOOL_RISK`: each driver tool's base tier. The context-dependent tools (click,
        /// press_key/hotkey, page) store a base here that `riskForToolCall` refines.
        ///
        /// DELIBERATE TRADEOFF (owner's model): `type_text`/`set_value` are `reversible`, not
        /// `mutating` — the product default is "draft, don't send"; composing text is reversible.
        static let base: [DriverTool: RiskLevel] = [
            // read_only — perception, pointer navigation, cursor overlay, config reads
            .startSession: .readOnly,
            .endSession: .readOnly,
            .setAgentCursorEnabled: .readOnly,
            .setAgentCursorMotion: .readOnly,
            .setAgentCursorStyle: .readOnly,
            .getAgentCursorState: .readOnly,
            .getWindowState: .readOnly,
            .getAccessibilityTree: .readOnly,
            .getCursorPosition: .readOnly,
            .getScreenSize: .readOnly,
            .listApps: .readOnly,
            .listWindows: .readOnly,
            .getRecordingState: .readOnly,
            .getConfig: .readOnly,
            .checkPermissions: .readOnly,
            .checkForUpdate: .readOnly,
            .zoom: .readOnly,
            .scroll: .readOnly,
            .moveCursor: .readOnly,
            // reversible / draft — composing, launching, foregrounding
            .typeText: .reversible,
            .setValue: .reversible,
            .launchApp: .reversible,
            .bringToFront: .reversible,
            // write_note (U3): writes a NEW titled .md into ~/Documents (confined, collision-safe,
            // never overwrites) — a reversible draft like type_text, so the compose-and-write
            // deliverable auto-runs rather than gating (KD1 / Q1 reversible-auto-run golden).
            .writeNote: .reversible,
            // bases; click/key/page get refined by riskForToolCall
            .click: .reversible,       // base: navigation; escalated to mutating on a commit element
            .rightClick: .reversible,  // base: opens a context menu (navigation)
            .doubleClick: .reversible, // base: open/activate; escalated on a commit element
            .drag: .mutating,
            .pressKey: .mutating,      // base: send-chords commit; de-escalated for nav keys
            .hotkey: .mutating,        // base: ⌘↵ etc. commit; de-escalated for nav keys
            .page: .mutating,          // base: execute_javascript / click_element; refined by action
            .setConfig: .mutating,
            .startRecording: .mutating,
            .stopRecording: .mutating,
            // destructive_external — process kill, AppleEvents patch, replay, installs
            .killApp: .destructiveExternal,
            .replayTrajectory: .destructiveExternal,
            .installFfmpeg: .destructiveExternal,
        ]

        /// `COMMIT_PATTERNS`: a click whose target element commits (sends/deletes/buys) gates
        /// even though a bare click is free navigation. Word-ish, case-insensitive match.
        static let commitPatterns: [String] = [
            "send", "post", "submit", "reply", "delete", "remove", "buy",
            "purchase", "order", "confirm", "pay", "publish", "discard", "trash",
        ]

        /// `NAVIGATION_KEYS`: keys that move focus/scroll without committing. Anything NOT here
        /// (return/enter, ⌘-chords, …) keeps press_key/hotkey gated.
        private static let navigationKeys: Set<String> = [
            "up", "down", "left", "right", "pageup", "pagedown",
            "home", "end", "escape", "esc", "tab",
        ]

        /// `NAVIGATION_MODIFIERS`: `shift` is a non-committing modifier (shift+tab, shift+arrow).
        /// The action modifiers (cmd/ctrl/option/fn) DO change a nav key into a command, so a
        /// chord carrying any of those is gated.
        private static let navigationModifiers: Set<String> = ["shift"]

        private static let pageReadActions: Set<String> = ["get_text", "query_dom"]
        private static let pageDestructiveActions: Set<String> = ["enable_javascript_apple_events"]

        private static let clickTools: Set<DriverTool> = [.click, .rightClick, .doubleClick]
        private static let keyTools: Set<DriverTool> = [.pressKey, .hotkey]

        /// `riskForToolCall`: the single per-call gate. NEVER trusts a model-supplied risk —
        /// risk is derived from the tool (+ target) here.
        static func riskForToolCall(_ tool: DriverTool, target: ToolCallTarget? = nil) -> RiskLevel {
            if clickTools.contains(tool) {
                return clickTargetCommits(target) ? .mutating : .reversible
            }
            if keyTools.contains(tool) {
                return keyChordCommits(target) ? .mutating : .readOnly
            }
            if tool == .page {
                return pageRisk(target)
            }
            // Every tool is in `base`; the `?? .mutating` is an unreachable safe default.
            return base[tool] ?? .mutating
        }

        /// `riskForToolName`: an UNKNOWN tool name (outside the driver surface) defaults to
        /// `mutating` — gated. A tool we cannot classify must never auto-run. Used by the loop
        /// when it receives a tool name STRING straight from the model.
        static func riskForToolName(_ tool: String, target: ToolCallTarget? = nil) -> RiskLevel {
            guard let parsed = DriverTool.parse(tool) else { return .mutating }
            return riskForToolCall(parsed, target: target)
        }

        /// `effectiveToolCallRisk`: the MAX over a set of calls' per-call risks (read + send → send).
        static func effectiveRisk(of calls: [(tool: DriverTool, target: ToolCallTarget?)]) -> RiskLevel {
            RiskLevel.effective(of: calls.map { riskForToolCall($0.tool, target: $0.target) })
        }

        /// `toolCallRequiresApproval`: does this single call need approval before it runs?
        static func requiresApproval(_ tool: DriverTool, target: ToolCallTarget? = nil) -> Bool {
            riskForToolCall(tool, target: target).requiresApproval
        }

        // MARK: - Refinements

        /// `matchesCommitPattern`: word-ish match so "Resend"/"Description" don't trip
        /// "send"/"post" but "Send", "Send Now", "Re-send", "Post reply" do.
        static func matchesCommitPattern(_ text: String?) -> Bool {
            guard let text, !text.isEmpty else { return false }
            let haystack = text.lowercased()
            return commitPatterns.contains { verb in
                // (^|[^a-z])verb([^a-z]|$), case-insensitive — already lowercased.
                guard let pattern = try? NSRegularExpression(
                    pattern: "(^|[^a-z])\(NSRegularExpression.escapedPattern(for: verb))([^a-z]|$)")
                else { return false }
                let range = NSRange(haystack.startIndex..., in: haystack)
                return pattern.firstMatch(in: haystack, range: range) != nil
            }
        }

        /// A click target commits when its element metadata matches a commit verb. NO element
        /// metadata at all → we cannot prove navigation → gate (safe default).
        private static func clickTargetCommits(_ target: ToolCallTarget?) -> Bool {
            guard let element = target?.element else { return true }
            return matchesCommitPattern(element.title)
                || matchesCommitPattern(element.label)
                || matchesCommitPattern(element.value)
                || matchesCommitPattern(element.role)
        }

        private static func isNavigationKey(_ key: String) -> Bool {
            let k = key.lowercased()
            return navigationKeys.contains(k) || navigationModifiers.contains(k)
        }

        /// hotkey: a bare navigation chord doesn't commit; any action modifier or committing key
        /// does. press_key: only the explicit navigation set is free; unknown/missing key gates.
        private static func keyChordCommits(_ target: ToolCallTarget?) -> Bool {
            if let keys = target?.keys, !keys.isEmpty {
                return !keys.allSatisfy(isNavigationKey)
            }
            if let key = target?.key {
                return !navigationKeys.contains(key.lowercased())
            }
            return true
        }

        /// `page` sub-actions split by risk: reads are free, JS/DOM mutation gates, the
        /// AppleEvents patch is destructive_external.
        private static func pageRisk(_ target: ToolCallTarget?) -> RiskLevel {
            guard let action = target?.pageAction else { return .mutating }
            if pageDestructiveActions.contains(action) { return .destructiveExternal }
            if pageReadActions.contains(action) { return .readOnly }
            return .mutating
        }
    }
}
