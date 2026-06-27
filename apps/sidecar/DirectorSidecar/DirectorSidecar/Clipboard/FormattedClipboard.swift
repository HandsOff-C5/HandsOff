//
//  FormattedClipboard.swift
//  DirectorSidecar
//
//  The thin SIDE-EFFECT layer over the pure `ClipboardRepresentationBuilder`: it writes the
//  multiple representations (RTF, HTML, plain-text fallback) onto an NSPasteboard so a later
//  paste (Cmd+V — owned by the actuation layer, NOT here) lands FORMATTED in apps like Slack.
//
//  Construction stays in `ClipboardContent.swift` (headlessly testable). This file is the only
//  place that touches `NSPasteboard`, and it is intentionally tiny.
//

import Foundation
import AppKit

/// Writes formatted content to a pasteboard. The director's actuation layer invokes
/// `write(_:)` to stage the clipboard, then focuses the target field and issues Cmd+V
/// (reused from #148) to drop it — this type performs the WRITE only.
enum FormattedClipboard {

    /// Stage `content` on `pasteboard` (defaults to the system pasteboard) with RTF first so
    /// rich targets prefer the formatted representation, falling back HTML → plain text.
    @discardableResult
    static func write(_ content: ClipboardContent, to pasteboard: NSPasteboard = .general) -> ClipboardRepresentations {
        let reps = ClipboardRepresentationBuilder.make(content)
        // declareTypes order == preference order: a rich editor takes RTF, then HTML, then string.
        pasteboard.clearContents()
        pasteboard.declareTypes([.rtf, .html, .string], owner: nil)
        pasteboard.setData(reps.rtf, forType: .rtf)
        pasteboard.setString(reps.html, forType: .html)
        pasteboard.setString(reps.plainText, forType: .string)
        return reps
    }
}
