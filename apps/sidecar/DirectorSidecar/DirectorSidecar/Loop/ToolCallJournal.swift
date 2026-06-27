//
//  ToolCallJournal.swift
//  DirectorSidecar
//
//  A durable, append-only sink for tool-call audit records (#158, observability gap). The Intention
//  Log (`ActionAuditStore` / `SupervisionAuditEvent`) is IN-MEMORY only — once a goal ends its trail
//  is gone — and Director's os_log tool-call traces are `.info` level, which macOS does NOT persist,
//  so a non-converging failure like the Catalyst no-op spin is undiagnosable after the fact. This
//  writes ONE JSON line per executed tool call (the dispatched tool + flat args + the raw driver
//  result) under Application Support, so the args-and-response history survives the session.
//
//  Privacy: the user's raw transcript is NOT persisted, and free-text args (`text`/`value` — what a
//  type_text/set_value would commit, potentially a password) are redacted to a length marker. The
//  structural args that diagnose a click loop (element_index/token, pid, window_id, x/y) are kept.
//

import Foundation
import OSLog

/// One persisted tool-call record — a flat projection of a `SupervisionAuditEvent.toolCall` plus the
/// dispatched args, sufficient to replay/diagnose a tool-call sequence post-hoc.
struct ToolCallJournalEntry: Codable, Sendable, Equatable {
    let recordedAt: String
    let sessionId: String
    let actionId: String
    let tool: String
    let args: Contracts.JSONValue   // flat dispatched args, free text redacted (see `redactingArgs`)
    let risk: String
    let approval: String
    let resultStatus: String        // succeeded | failed | blocked
    let resultDetail: String        // summary / error / reason — the raw driver response text

    /// Arg keys whose VALUE is free text the user authored — redacted to a length marker so a typed
    /// secret never lands on disk. The keys themselves are kept so the shape stays diagnosable.
    private static let redactedKeys: Set<String> = ["text", "value"]

    /// The dispatched args as a JSON object with free-text values redacted.
    static func redactingArgs(_ args: [String: Contracts.JSONValue]) -> Contracts.JSONValue {
        var out = args
        for key in redactedKeys where out[key] != nil {
            if case let .string(value)? = out[key] {
                out[key] = .string("<redacted:\(value.count) chars>")
            } else {
                out[key] = .string("<redacted>")
            }
        }
        return .object(out)
    }
}

/// The seam the loop records each tool call through. The app injects the on-disk `ToolCallJournal`;
/// tests inject a fake (or nil) so a headless run writes nothing.
protocol ToolCallSink: Sendable {
    func record(_ entry: ToolCallJournalEntry)
}

/// Append-only JSONL sink at `~/Library/Application Support/<bundleID>/tool-calls.jsonl`. Writes run
/// off the main actor on a serial queue (ordered, non-blocking); every failure is logged at a level
/// macOS persists and then swallowed, so a disk problem never disturbs the supervision loop.
final class ToolCallJournal: ToolCallSink, @unchecked Sendable {
    private let fileURL: URL
    private let queue = DispatchQueue(label: "com.handsoff.tool-call-journal", qos: .utility)
    private let encoder: JSONEncoder

    /// The default journal path — mirrors `LocalConfigService.defaultConfigURL`'s resolution so the
    /// audit log sits beside the existing on-disk state.
    static func defaultURL(
        fileManager: FileManager = .default,
        bundleID: String = Bundle.main.bundleIdentifier ?? "com.handsoff.desktop"
    ) throws -> URL {
        let base = try fileManager.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
        return base.appendingPathComponent(bundleID, isDirectory: true)
            .appendingPathComponent("tool-calls.jsonl", isDirectory: false)
    }

    init(fileURL: URL) {
        self.fileURL = fileURL
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
        self.encoder = encoder
    }

    /// A journal at the default path, or nil if the path can't be resolved (best-effort wiring).
    convenience init?() {
        guard let url = try? Self.defaultURL() else { return nil }
        self.init(fileURL: url)
    }

    func record(_ entry: ToolCallJournalEntry) {
        queue.async { [fileURL, encoder] in
            Self.append(entry, to: fileURL, encoder: encoder)
        }
    }

    /// Block until all queued writes have flushed — for tests and orderly shutdown.
    func flush() { queue.sync {} }

    /// Encode one entry as a single JSONL line and append it, creating the directory + file as needed.
    private static func append(_ entry: ToolCallJournalEntry, to url: URL, encoder: JSONEncoder) {
        do {
            var line = try encoder.encode(entry)
            line.append(0x0A)  // newline-delimited JSON
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: line)
            } else {
                try line.write(to: url, options: .atomic)  // first write creates the file
            }
        } catch {
            DirectorDiagnostics.services.warning(
                "tool-call journal append failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

extension Contracts.CuaActionResult {
    /// The discriminant for the durable journal (`succeeded`/`failed`/`blocked`).
    var journalStatus: String {
        switch self {
        case .succeeded: return "succeeded"
        case .failed: return "failed"
        case .blocked: return "blocked"
        }
    }

    /// The raw driver response text — the summary, error, or reason carried by the result.
    var journalDetail: String {
        switch self {
        case let .succeeded(summary, _): return summary
        case let .failed(error, _): return error
        case let .blocked(reason, _): return reason
        }
    }
}
