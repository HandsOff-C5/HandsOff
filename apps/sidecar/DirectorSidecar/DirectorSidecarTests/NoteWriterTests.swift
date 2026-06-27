//
//  NoteWriterTests.swift
//  DirectorSidecarTests
//
//  The compose-and-write capability (plan U3): writes generated text to a confined Documents
//  directory, sanitizes the title against path traversal, and picks a unique name on collision.
//  Tests inject a per-test temp directory as the confined root and a no-op `open` so nothing
//  launches and the real Documents folder is never touched.
//

import Testing
import Foundation
@testable import DirectorSidecar

struct NoteWriterTests {
    /// A fresh confined-root directory and a NoteWriter that opens nothing.
    private func makeWriter() -> (writer: NoteWriter, root: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ho-notes-\(UUID().uuidString)", isDirectory: true)
        let writer = NoteWriter(documentsDirectory: root, open: { _ in })
        return (writer, root)
    }

    @Test func writesTextAndReturnsPathInsideDocuments() throws {
        let (writer, root) = makeWriter()
        defer { try? FileManager.default.removeItem(at: root) }

        let url = try writer.writeNote(title: "Issue summary", text: "the body")

        #expect(url.lastPathComponent == "Issue summary.md")
        #expect(url.deletingLastPathComponent().standardizedFileURL.path == root.standardizedFileURL.path)
        #expect(FileManager.default.fileExists(atPath: url.path))
        let written = try String(contentsOf: url, encoding: .utf8)
        #expect(written == "the body")
    }

    @Test func sanitizesSeparatorsTraversalAndControlCharsAndStaysInside() throws {
        let (writer, root) = makeWriter()
        defer { try? FileManager.default.removeItem(at: root) }

        let url = try writer.writeNote(title: "../../etc/pas:swd\u{0007}\nx", text: "safe")

        let name = url.lastPathComponent
        #expect(!name.contains("/"))
        #expect(!name.contains(".."))
        #expect(!name.contains(":"))
        #expect(!name.contains("\u{0007}"))
        // The file lands directly in the confined root — traversal did not escape.
        #expect(url.deletingLastPathComponent().standardizedFileURL.path == root.standardizedFileURL.path)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test func emptyOrSeparatorOnlyTitleFallsBackToDefault() {
        #expect(NoteWriter.sanitizedBase(from: "") == "Note")
        #expect(NoteWriter.sanitizedBase(from: "///") == "Note")
        #expect(NoteWriter.sanitizedBase(from: "..") == "Note")
        #expect(NoteWriter.sanitizedBase(from: "   ") == "Note")
    }

    @Test func collisionYieldsUniqueNameWithoutOverwriting() throws {
        let (writer, root) = makeWriter()
        defer { try? FileManager.default.removeItem(at: root) }

        let first = try writer.writeNote(title: "Notes", text: "first")
        let second = try writer.writeNote(title: "Notes", text: "second")

        #expect(first.lastPathComponent == "Notes.md")
        #expect(second.lastPathComponent != first.lastPathComponent)
        #expect(second.lastPathComponent == "Notes (2).md")
        // Original is untouched; the second write went to a distinct file.
        #expect(try String(contentsOf: first, encoding: .utf8) == "first")
        #expect(try String(contentsOf: second, encoding: .utf8) == "second")
    }

    @Test func opensTheWrittenFile() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ho-notes-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        var opened: [URL] = []
        let writer = NoteWriter(documentsDirectory: root, open: { opened.append($0) })
        let url = try writer.writeNote(title: "Open me", text: "x")

        #expect(opened == [url])
    }
}
