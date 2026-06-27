//
//  ToolCallJournalTests.swift
//  DirectorSidecarTests
//
//  The durable tool-call audit sink (#158): JSONL append + round-trip, append-across-instances, and
//  free-text-arg redaction. Writes to a per-test temp directory (never the real Application Support).
//

import Testing
import Foundation
@testable import DirectorSidecar

struct ToolCallJournalTests {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ho-journal-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("tool-calls.jsonl", isDirectory: false)
    }

    private func entry(tool: String, status: String = "succeeded", detail: String = "ok") -> ToolCallJournalEntry {
        ToolCallJournalEntry(
            recordedAt: "2026-06-27T00:00:00.000Z", sessionId: "s1", actionId: "a1",
            tool: tool, args: .object(["pid": .number(42), "element_index": .number(0)]),
            risk: "reversible", approval: "auto", resultStatus: status, resultDetail: detail)
    }

    @Test func appendsOneJsonLinePerRecordAndRoundTrips() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let journal = ToolCallJournal(fileURL: url)
        journal.record(entry(tool: "click"))
        journal.record(entry(tool: "scroll", status: "failed", detail: "AXConfirm -25200"))
        journal.flush()

        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map(String.init)
        #expect(lines.count == 2)
        let decoded = try lines.map { try JSONDecoder().decode(ToolCallJournalEntry.self, from: Data($0.utf8)) }
        #expect(decoded[0].tool == "click")
        #expect(decoded[0].resultStatus == "succeeded")
        #expect(decoded[1].tool == "scroll")
        #expect(decoded[1].resultStatus == "failed")
        #expect(decoded[1].resultDetail == "AXConfirm -25200")
    }

    @Test func appendsAcrossInstancesInsteadOfTruncating() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let first = ToolCallJournal(fileURL: url)
        first.record(entry(tool: "click")); first.flush()
        // A fresh journal at the same path appends — the trail survives a restart.
        let second = ToolCallJournal(fileURL: url)
        second.record(entry(tool: "type_text")); second.flush()
        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
        #expect(lines.count == 2)
    }

    @Test func redactsFreeTextArgsButKeepsStructuralArgs() throws {
        let args: [String: Contracts.JSONValue] = [
            "pid": .number(42), "element_index": .number(3),
            "text": .string("hunter2 secret"), "value": .string("xyz"),
        ]
        guard case let .object(redacted) = ToolCallJournalEntry.redactingArgs(args) else {
            Issue.record("expected an object"); return
        }
        #expect(redacted["pid"] == .number(42))            // structural args kept
        #expect(redacted["element_index"] == .number(3))
        #expect(redacted["text"] == .string("<redacted:14 chars>"))  // free text never hits disk
        #expect(redacted["value"] == .string("<redacted:3 chars>"))
    }
}
