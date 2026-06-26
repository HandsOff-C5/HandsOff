//
//  ToolCallTarget.swift
//  DirectorSidecar
//
//  Port of @handsoff/contracts tool-risk.ts `toolCallTargetSchema` — the risk-relevant subset
//  of what a single driver tool call targets. The driver owns each tool's full per-arg schema;
//  this models only the optional fields the local risk gate and the per-call audit record need.
//  Everything is optional: a click that arrives with no element info cannot be proven to be
//  navigation, so the gate treats it as committing (safe default).
//

import Foundation

extension Contracts {
    /// `toolCallTargetSchema`.
    struct ToolCallTarget: Codable, Sendable, Equatable {
        /// The AX element a click / double_click / right_click addresses.
        let element: Element?
        /// For press_key: the key name (e.g. "return", "down").
        let key: String?
        /// For hotkey: the chord, e.g. ["cmd", "return"].
        let keys: [String]?
        /// For page: the sub-action ("execute_javascript" | "get_text" | …).
        let pageAction: String?

        struct Element: Codable, Sendable, Equatable {
            let role: String?
            let title: String?
            let label: String?
            let value: String?
        }
    }
}
