//
//  ClipboardContent.swift
//  DirectorSidecar
//
//  The PURE structure → representations builder for the formatted-drop clipboard primitive
//  (Phase 5b, Beat 1: copy a README code block from Cursor, drop it FORMATTED into Slack).
//
//  This file owns the localized value types (no Envelope import — A-25: localize any needed
//  value type as internal) and the deterministic construction of the three pasteboard
//  representations: an NSAttributedString, an RTF `Data`, and an HTML `String`, plus the
//  plain-text fallback. It performs NO NSPasteboard write — that side effect lives in
//  `FormattedClipboard` — so the construction is unit-testable headlessly.
//

import Foundation
import AppKit

/// What we are about to drop onto the clipboard. Kept internal + self-contained so the clipboard
/// primitive does not couple to the bridge/Envelope referent shapes.
enum ClipboardContent: Equatable {
    /// Plain prose — a single run of body text.
    case text(String)
    /// A README-style block: an optional heading followed by a fenced code block — Beat 1's
    /// "heading + code" shape lifted from a Cursor README. `language` is the fence info-string
    /// (e.g. "swift"); it is advisory and only annotates the HTML `<code>` class.
    case codeBlock(heading: String?, code: String, language: String? = nil)
}

/// The bundle of representations a single `ClipboardContent` produces. Highest-fidelity first:
/// RTF and HTML carry the formatting (heading + monospaced/preformatted code) so a rich target
/// like the Slack composer renders code as code; `plainText` is the universal fallback.
struct ClipboardRepresentations {
    let attributed: NSAttributedString
    let rtf: Data
    let html: String
    let plainText: String
}

/// The pure construction seam: `ClipboardContent` → `ClipboardRepresentations`. No I/O, no
/// pasteboard — every output is derived deterministically from the input, so it is testable
/// without a window server.
enum ClipboardRepresentationBuilder {

    // Typography. A named monospaced face (Menlo) is used deliberately for code so the RTF run
    // carries an unmistakable monospaced font — that monospaced run is the signal rich editors
    // (Slack) use to render the paste as code.
    private static let bodySize: CGFloat = 13
    private static let headingSize: CGFloat = 15
    private static let monospaceFontName = "Menlo"

    static func make(_ content: ClipboardContent) -> ClipboardRepresentations {
        switch content {
        case let .text(body):
            let attributed = NSAttributedString(string: body, attributes: [
                .font: NSFont.systemFont(ofSize: bodySize)
            ])
            return ClipboardRepresentations(
                attributed: attributed,
                rtf: rtf(from: attributed),
                html: htmlEscaping(body),
                plainText: body
            )

        case let .codeBlock(heading, code, language):
            let attributed = codeBlockAttributed(heading: heading, code: code)
            return ClipboardRepresentations(
                attributed: attributed,
                rtf: rtf(from: attributed),
                html: codeBlockHTML(heading: heading, code: code, language: language),
                plainText: codeBlockPlainText(heading: heading, code: code)
            )
        }
    }

    // MARK: - NSAttributedString

    private static func codeBlockAttributed(heading: String?, code: String) -> NSAttributedString {
        let out = NSMutableAttributedString()
        if let heading, !heading.isEmpty {
            out.append(NSAttributedString(string: heading + "\n", attributes: [
                .font: NSFont.boldSystemFont(ofSize: headingSize)
            ]))
            // A blank line between heading and code keeps the structure when pasted as plain runs.
            out.append(NSAttributedString(string: "\n", attributes: [
                .font: NSFont.systemFont(ofSize: bodySize)
            ]))
        }
        let mono = NSFont(name: monospaceFontName, size: bodySize)
            ?? NSFont.monospacedSystemFont(ofSize: bodySize, weight: .regular)
        out.append(NSAttributedString(string: code, attributes: [.font: mono]))
        return out
    }

    private static func rtf(from attributed: NSAttributedString) -> Data {
        // Full-range RTF; never nil for an in-memory attributed string.
        attributed.rtf(from: NSRange(location: 0, length: attributed.length),
                       documentAttributes: [:]) ?? Data()
    }

    // MARK: - HTML

    /// Heading as `<h3>`, code as `<pre><code>` so a preformatted block survives the paste even
    /// when the target prefers HTML over RTF. The `<pre>`/monospaced pairing is what makes Slack
    /// treat it as a code block.
    private static func codeBlockHTML(heading: String?, code: String, language: String?) -> String {
        var html = ""
        if let heading, !heading.isEmpty {
            html += "<h3>\(htmlEscaping(heading))</h3>\n"
        }
        let langClass = (language?.isEmpty == false) ? " class=\"language-\(htmlEscaping(language!))\"" : ""
        html += "<pre style=\"font-family:monospace\"><code\(langClass)>\(htmlEscaping(code))</code></pre>"
        return html
    }

    private static func htmlEscaping(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for ch in s {
            switch ch {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&#39;"
            default: out.append(ch)
            }
        }
        return out
    }

    // MARK: - Plain text

    private static func codeBlockPlainText(heading: String?, code: String) -> String {
        if let heading, !heading.isEmpty {
            return heading + "\n\n" + code
        }
        return code
    }
}
