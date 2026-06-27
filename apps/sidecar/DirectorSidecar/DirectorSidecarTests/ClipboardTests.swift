//
//  ClipboardTests.swift
//  DirectorSidecarTests
//
//  Phase 5b — the formatted-drop clipboard primitive. These tests drive the PURE
//  `ClipboardRepresentationBuilder` headlessly (no NSPasteboard write): given a heading + code
//  block they assert the RTF and HTML carry the heading and the code, that the code is
//  monospaced (RTF) / preformatted (HTML), and that a plain-text fallback is always present.
//  One test exercises the actual `FormattedClipboard` write against a NAMED (non-system)
//  NSPasteboard so it stays hermetic.
//

import Testing
import Foundation
import AppKit
@testable import DirectorSidecar

private let kHeading = "Quickstart"
private let kCode = "let x = greet(name: \"world\") // a > b && c < d"

/// Decode RTF Data back to a string we can search (the RTF control words + the literal text).
private func rtfString(_ data: Data) -> String {
    String(data: data, encoding: .utf8)
        ?? String(data: data, encoding: .isoLatin1)
        ?? ""
}

@Test func codeBlockRTFContainsHeadingAndMonospacedCode() {
    let reps = ClipboardRepresentationBuilder.make(.codeBlock(heading: kHeading, code: kCode))
    let rtf = rtfString(reps.rtf)

    #expect(!reps.rtf.isEmpty)
    // The heading text survives into the RTF run.
    #expect(rtf.contains(kHeading))
    // The code text survives. RTF escapes some chars (\{ \} \\) but the identifiers remain.
    #expect(rtf.contains("greet"))
    #expect(rtf.contains("world"))
    // Code is rendered in a monospaced face — the Menlo font name is embedded in the RTF
    // font table, which is the signal Slack uses to render the run as code.
    #expect(rtf.contains("Menlo"))
}

@Test func codeBlockHTMLIsPreformattedAndContainsContent() {
    let reps = ClipboardRepresentationBuilder.make(.codeBlock(heading: kHeading, code: kCode, language: "swift"))
    let html = reps.html

    // Heading is a heading element; code is a preformatted code block.
    #expect(html.contains("<h3>\(kHeading)</h3>"))
    #expect(html.contains("<pre"))
    #expect(html.contains("<code"))
    #expect(html.contains("language-swift"))
    // The code content is present and HTML-escaped (no raw < > & " that would break markup).
    #expect(html.contains("greet"))
    #expect(html.contains("&gt;"))   // the `>` in the code
    #expect(html.contains("&lt;"))   // the `<` in the code
    #expect(html.contains("&amp;"))  // the `&&` in the code
    #expect(!html.contains("a > b"))   // raw, unescaped form must NOT appear
}

@Test func codeBlockPlainTextFallbackPresent() {
    let reps = ClipboardRepresentationBuilder.make(.codeBlock(heading: kHeading, code: kCode))
    // No language tag → plain fence.
    let expected = kHeading + "\n\n" + "```\n" + kCode + "\n```"
    #expect(reps.plainText == expected)
    // Plain text is verbatim — never escaped.
    #expect(reps.plainText.contains("a > b && c < d"))
}

@Test func codeBlockPlainTextPreservesFenceAndLanguageTag() {
    let reps = ClipboardRepresentationBuilder.make(.codeBlock(heading: kHeading, code: kCode, language: "swift"))
    // The opening fence must carry the language info-string.
    #expect(reps.plainText.hasPrefix(kHeading + "\n\n```swift\n"))
    #expect(reps.plainText.hasSuffix("\n```"))
    // The code body is still present verbatim.
    #expect(reps.plainText.contains(kCode))
}

@Test func codeBlockAttributedUsesMonospacedFontForCodeRun() {
    let reps = ClipboardRepresentationBuilder.make(.codeBlock(heading: kHeading, code: kCode))
    let attr = reps.attributed
    // The last character (inside the code run) must be monospaced; the first (heading) must not.
    let codeFont = attr.attribute(.font, at: attr.length - 1, effectiveRange: nil) as? NSFont
    let headFont = attr.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
    #expect(codeFont?.isFixedPitch == true)
    #expect(headFont?.isFixedPitch != true)
}

@Test func codeBlockWithoutHeadingOmitsHeadingMarkup() {
    let reps = ClipboardRepresentationBuilder.make(.codeBlock(heading: nil, code: kCode))
    #expect(!reps.html.contains("<h3>"))
    #expect(reps.html.contains("<pre"))
    // No heading → fence only, no heading prefix.
    #expect(reps.plainText == "```\n" + kCode + "\n```")
}

@Test func plainTextContentProducesAllThreeRepresentations() {
    let body = "just some prose"
    let reps = ClipboardRepresentationBuilder.make(.text(body))
    #expect(reps.plainText == body)
    #expect(reps.html.contains(body))
    #expect(!reps.rtf.isEmpty)
    #expect(rtfString(reps.rtf).contains(body))
}

@Test func writePlacesAllThreeTypesOnPasteboard() {
    // A NAMED pasteboard keeps the test hermetic (does not clobber the user's clipboard).
    let pb = NSPasteboard(name: NSPasteboard.Name("DirectorSidecarTests.clipboard"))
    let reps = FormattedClipboard.write(.codeBlock(heading: kHeading, code: kCode, language: "swift"), to: pb)

    let types = pb.types ?? []
    #expect(types.contains(.rtf))
    #expect(types.contains(.html))
    #expect(types.contains(.string))
    // RTF is declared first → it is the preferred (highest-priority) representation.
    #expect(types.first == .rtf)

    #expect(pb.data(forType: .rtf) == reps.rtf)
    #expect(pb.string(forType: .html) == reps.html)
    #expect(pb.string(forType: .string) == kHeading + "\n\n" + "```swift\n" + kCode + "\n```")
}
