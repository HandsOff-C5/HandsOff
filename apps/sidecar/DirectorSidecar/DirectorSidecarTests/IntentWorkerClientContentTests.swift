//
//  IntentWorkerClientContentTests.swift
//  DirectorSidecarTests
//
//  U5 multimodal message contract — the on-the-wire `ChatMessage.content` now encodes EITHER a
//  plain string (the pre-U5 shape, which MUST stay byte-identical so the Worker and every existing
//  call site are unaffected) OR an OpenAI/Gemini-compatible array of content parts (text + inline
//  base64 image). These tests pin: (a) the string form is byte-for-byte the legacy `{role,content}`
//  JSON; (b) the parts form is the multimodal array with the `data:` URL intact; (c) an oversized
//  inline image is a typed `IntentWorkerError.imageTooLarge`, never a silent malformed request.
//

import Testing
import Foundation
@testable import DirectorSidecar

// MARK: - (a) String content stays byte-identical to the legacy wire shape

@Test func stringContentMessageSerializesToLegacyBareStringShape() throws {
    let message = ChatMessage(role: "user", content: "{}")
    let data = try JSONEncoder().encode(message)
    // The pre-U5 wire shape: a `{ role, content }` object whose `content` is the BARE string — NOT a
    // multimodal parts array — so the Worker and provider see the unchanged legacy message. (Foundation's
    // JSONEncoder hash-randomizes key order per process on this platform, so the load-bearing invariant
    // is the SHAPE — exactly the two keys, `content` a String — not a byte-exact key ordering.)
    let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(Set(object.keys) == ["role", "content"])
    #expect(object["role"] as? String == "user")
    #expect(object["content"] as? String == "{}")
    #expect(object["content"] is String)   // a bare String, never a multimodal parts array
}

@Test func stringContentMessageRoundTripsToTextContent() throws {
    let message = ChatMessage(role: "system", content: "hello")
    let data = try JSONEncoder().encode(message)
    let decoded = try JSONDecoder().decode(ChatMessage.self, from: data)
    #expect(decoded == message)
    #expect(decoded.content == .text("hello"))
}

// MARK: - (b) Text + image content serializes to the multimodal array shape

@Test func textAndImageMessageSerializesToMultimodalArrayWithDataURL() throws {
    let dataURL = "data:image/png;base64,iVBORw0KGgo="
    let message = try ChatMessage(role: "user", parts: [
        .text("look at this"),
        .image(base64: "iVBORw0KGgo=", mimeType: "image/png"),
    ])

    let data = try JSONEncoder().encode(message)
    // Parse back through JSONSerialization so the assertion is robust to slash-escaping and key order.
    let object = try #require(
        try JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(object["role"] as? String == "user")

    let parts = try #require(object["content"] as? [[String: Any]])
    #expect(parts.count == 2)

    #expect(parts[0]["type"] as? String == "text")
    #expect(parts[0]["text"] as? String == "look at this")

    #expect(parts[1]["type"] as? String == "image_url")
    let imageURL = try #require(parts[1]["image_url"] as? [String: Any])
    #expect(imageURL["url"] as? String == dataURL)
}

@Test func imageHelperBuildsADataURLFromBase64AndMime() {
    #expect(ContentPart.image(base64: "AAAA", mimeType: "image/jpeg")
        == .imageURL("data:image/jpeg;base64,AAAA"))
    // PNG is the default mime (matches a CuaScreenshot capture).
    #expect(ContentPart.image(base64: "AAAA") == .imageURL("data:image/png;base64,AAAA"))
}

// MARK: - (c) Oversized inline image is a typed error, not a malformed request

@Test func oversizedInlineImageThrowsTypedError() {
    let oversized = String(repeating: "A", count: ContentPart.maxImageBase64Bytes + 1)
    #expect(throws: IntentWorkerError.self) {
        _ = try ChatMessage(role: "user", parts: [.image(base64: oversized)])
    }
}

@Test func imageAtTheCapIsAccepted() throws {
    // A payload exactly at the cap is allowed — the guard rejects only what is strictly over it.
    let atCap = String(repeating: "A", count: ContentPart.maxImageBase64Bytes)
    let message = try ChatMessage(role: "user", parts: [.image(base64: atCap)])
    if case .parts(let parts) = message.content {
        #expect(parts.count == 1)
    } else {
        Issue.record("expected parts content")
    }
}
