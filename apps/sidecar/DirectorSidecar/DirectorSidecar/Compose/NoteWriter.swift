//
//  NoteWriter.swift
//  DirectorSidecar
//
//  The compose-and-write "skill" surface (plan U3). `write_note(title, text)` is a locally-handled
//  tool: the agent generates a deliverable and hands it here to be persisted as a real file the user
//  can open, instead of typing the request verbatim into some app. This file is the native capability
//  only — the resolver menu entry and loop dispatch interception are wired separately.
//
//  Security: writes are confined strictly to the user's Documents directory. The supplied `title` is
//  sanitized to a single filename component (no `/`, `..`, or control characters), so a malicious or
//  model-hallucinated title cannot traverse out of Documents. Writes are collision-safe and never
//  overwrite an existing file — a unique name is chosen instead.
//

import Foundation
import AppKit
import OSLog

/// Persists model-generated text as a Markdown note inside `~/Documents` and opens it.
///
/// `documentsDirectory` and `open` are injectable purely for testing; production callers use the
/// zero-argument initializer, which resolves the real Documents directory and opens via `NSWorkspace`.
struct NoteWriter {
    enum NoteWriterError: Error, Equatable {
        /// The sanitized filename resolved outside the confined Documents directory (defense-in-depth).
        case escapesDocuments
        /// No free filename was found after the collision-resolution cap.
        case exhaustedUniqueNames
        /// The underlying file write failed for a reason other than an existing-file collision.
        case writeFailed(String)
    }

    /// Hard cap on the sanitized base name length (filesystem-safe, leaves room for the " (N).md" suffix).
    private static let maxBaseLength = 120
    /// Upper bound on collision-resolution attempts before giving up.
    private static let maxCollisionAttempts = 10_000
    /// Fallback base name when the title sanitizes to nothing usable.
    private static let defaultBase = "Note"

    let documentsDirectory: URL
    private let open: (URL) -> Void

    init(
        documentsDirectory: URL? = nil,
        open: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) }
    ) {
        self.documentsDirectory = documentsDirectory ?? NoteWriter.defaultDocumentsDirectory()
        self.open = open
    }

    /// Writes `text` to `~/Documents/<sanitized title>.md` (collision-safe), opens it, and returns the URL.
    @discardableResult
    func writeNote(title: String, text: String) throws -> URL {
        let base = NoteWriter.sanitizedBase(from: title)
        try FileManager.default.createDirectory(
            at: documentsDirectory, withIntermediateDirectories: true)

        var lastError: Error?
        for index in 1...NoteWriter.maxCollisionAttempts {
            let fileName = index == 1 ? "\(base).md" : "\(base) (\(index)).md"
            let url = documentsDirectory.appendingPathComponent(fileName, isDirectory: false)

            // Defense-in-depth: the sanitized base carries no separators, so the parent is always
            // Documents — but re-verify before any write so a future sanitize regression cannot escape.
            guard url.deletingLastPathComponent().standardizedFileURL.path
                == documentsDirectory.standardizedFileURL.path else {
                throw NoteWriterError.escapesDocuments
            }

            do {
                try Data(text.utf8).write(to: url, options: [.withoutOverwriting])
                open(url)
                DirectorDiagnostics.services.info(
                    "write_note wrote \(url.lastPathComponent, privacy: .public) (\(text.count, privacy: .public) chars)")
                return url
            } catch let error as NSError
                where error.domain == NSCocoaErrorDomain && error.code == NSFileWriteFileExistsError {
                // Name taken — try the next collision-safe candidate, never overwrite.
                lastError = error
                continue
            } catch {
                DirectorDiagnostics.services.error(
                    "write_note failed for \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
                throw NoteWriterError.writeFailed(error.localizedDescription)
            }
        }
        throw lastError.map { NoteWriterError.writeFailed($0.localizedDescription) }
            ?? NoteWriterError.exhaustedUniqueNames
    }

    // MARK: - Sanitization

    /// Reduces an arbitrary title to a single safe filename component (no separators, control chars,
    /// or `..` traversal). Returns ``defaultBase`` when nothing usable remains.
    static func sanitizedBase(from title: String) -> String {
        // 1. Neutralize control characters and every path separator (POSIX `/`, HFS `:`, Windows `\`).
        let mapped = String(String.UnicodeScalarView(title.unicodeScalars.map { scalar in
            if CharacterSet.controlCharacters.contains(scalar) { return " " }
            if scalar == "/" || scalar == ":" || scalar == "\\" { return "-" }
            return scalar
        }))

        // 2. Collapse `..` runs so no component reads as a parent-directory reference.
        var collapsed = mapped
        while collapsed.contains("..") {
            collapsed = collapsed.replacingOccurrences(of: "..", with: ".")
        }

        // 3. Trim leading/trailing dots, separators-turned-hyphens, and whitespace (a leading dot
        //    makes a hidden file; trailing dots/spaces are stripped by the filesystem anyway; a
        //    separator-only title like "///" collapses to nothing and falls back to the default).
        let trimmed = collapsed.trimmingCharacters(
            in: CharacterSet(charactersIn: ".- ").union(.whitespacesAndNewlines))

        // 4. Bound the length, then fall back if empty.
        let bounded = String(trimmed.prefix(maxBaseLength))
        return bounded.isEmpty ? defaultBase : bounded
    }

    private static func defaultDocumentsDirectory() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Documents", isDirectory: true)
    }
}
