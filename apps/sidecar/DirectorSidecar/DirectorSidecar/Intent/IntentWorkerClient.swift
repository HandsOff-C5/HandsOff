//
//  IntentWorkerClient.swift
//  DirectorSidecar
//
//  The Worker client for the LLM next-tool-call resolver (Track C) — the native replacement
//  for the injected OpenAI client in @handsoff/intent. The provider boundary is preserved
//  EXACTLY: the app never holds the OpenAI key. It POSTs `{ model, messages }` to the CF
//  Worker (workers/llm-intent `/v1/resolve-intent`) with `Authorization: Bearer <app token>`;
//  the Worker holds `OPENAI_API_KEY`, runs the structured-output completion against
//  `nextToolCallSchema`, and returns `{ choices }`. The Swift side only sees the same parsed
//  next-tool-call shape the TS resolver consumed.
//
//  `NextToolCallClient` is the injection seam (mirrors the TS `OpenAiIntentClient`): the
//  resolver depends on the protocol, tests inject a canned-response stub, and the concrete
//  `IntentWorkerClient` talks to the live Worker.
//

import Foundation

/// One chat message on the wire — `{ role, content }`, forwarded verbatim by the Worker to the
/// provider. `content` is polymorphic, matching the OpenAI/Gemini message shape:
///   - a bare JSON string (system/user text — the legacy, pre-U5 shape), or
///   - a JSON array of `ContentPart`s (the multimodal/vision shape) — a text part and/or an
///     inline base64 image part.
/// A string-content message encodes byte-identically to the pre-U5 shape (`{"role":…,"content":"…"}`)
/// so the Worker and every existing call site see no change; the Worker already forwards a
/// content array opaquely (`messages: unknown[]`), so the wire model is the only thing that grows.
/// (Lives with `IntentRequestBody` — this is the wire body's content type, not prompt logic.)
struct ChatMessage: Codable, Sendable, Equatable {
    let role: String
    let content: Content

    /// `content` is either a plain string or an ordered array of parts. Modeled as an enum so the
    /// two on-the-wire forms stay explicit and the string form can be encoded byte-for-byte as before.
    enum Content: Sendable, Equatable {
        case text(String)
        case parts([ContentPart])
    }

    /// Legacy string-content message. Encodes to `{"role":…,"content":"<text>"}` — byte-identical
    /// to the pre-U5 shape, so existing call sites (the prompt builder's system/user turns) and the
    /// Worker are unaffected.
    init(role: String, content: String) {
        self.role = role
        self.content = .text(content)
    }

    /// Multimodal message: `content` becomes a JSON array of parts (text and/or image), the
    /// OpenAI/Gemini vision shape. Validates each part up front — throws
    /// `IntentWorkerError.imageTooLarge` if any inline image's base64 payload exceeds
    /// `ContentPart.maxImageBase64Bytes`, so an oversized image is a typed failure here rather
    /// than a malformed/oversized request the Worker would forward.
    init(role: String, parts: [ContentPart]) throws {
        try parts.forEach { try $0.validate() }
        self.role = role
        self.content = .parts(parts)
    }

    private enum Key: String, CodingKey { case role, content }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: Key.self)
        try container.encode(role, forKey: .role)
        switch content {
        // The string form encodes the bare string for `content` — the exact pre-U5 output.
        case let .text(text): try container.encode(text, forKey: .content)
        case let .parts(parts): try container.encode(parts, forKey: .content)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Key.self)
        role = try container.decode(String.self, forKey: .role)
        // `content` is a string or an array of parts; try the string form first (the common case).
        if let text = try? container.decode(String.self, forKey: .content) {
            content = .text(text)
        } else {
            content = .parts(try container.decode([ContentPart].self, forKey: .content))
        }
    }
}

/// One part of a multimodal `content` array — the OpenAI/Gemini vision message shapes:
///   text  → `{"type":"text","text":"…"}`
///   image → `{"type":"image_url","image_url":{"url":"data:image/png;base64,…"}}`
enum ContentPart: Codable, Sendable, Equatable {
    case text(String)
    /// A full image URL — typically an inline `data:<mime>;base64,<payload>` data URL.
    case imageURL(String)

    /// Build an inline image part from a captured PNG (e.g. a `CuaScreenshot`'s `mimeType` +
    /// `pngBase64`), assembling the `data:<mime>;base64,<payload>` URL the provider expects.
    static func image(base64 payload: String, mimeType: String = "image/png") -> ContentPart {
        .imageURL("data:\(mimeType);base64,\(payload)")
    }

    /// Cap on an inline image's base64 payload. 10 MiB of base64 (~7.5 MB of decoded PNG) sits
    /// comfortably above a Retina full-window screenshot yet well under the provider's request-size
    /// limit, so an over-cap image is rejected here as a typed error instead of being forwarded as a
    /// malformed/oversized request the provider would reject with a 400/413.
    static let maxImageBase64Bytes = 10 * 1024 * 1024

    /// The base64 payload of a `data:…;base64,…` image part, or nil for a text part or a non-base64
    /// (remote `https`) image URL — neither carries an inline payload to bound.
    var inlineImageBase64: String? {
        guard case let .imageURL(url) = self,
              let range = url.range(of: ";base64,") else { return nil }
        return String(url[range.upperBound...])
    }

    /// Reject an inline image whose base64 payload exceeds the cap. No-op for text/remote parts.
    func validate() throws {
        guard let payload = inlineImageBase64 else { return }
        let byteCount = payload.utf8.count
        guard byteCount <= ContentPart.maxImageBase64Bytes else {
            throw IntentWorkerError.imageTooLarge(
                "image-too-large: inline image base64 is \(byteCount) bytes, over the " +
                "\(ContentPart.maxImageBase64Bytes)-byte cap")
        }
    }

    private enum Key: String, CodingKey {
        case type
        case text
        case imageURL = "image_url"
    }

    /// The nested `{ "url": … }` object an `image_url` part wraps.
    private struct ImageURLBox: Codable, Equatable { let url: String }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: Key.self)
        switch self {
        case let .text(text):
            try container.encode("text", forKey: .type)
            try container.encode(text, forKey: .text)
        case let .imageURL(url):
            try container.encode("image_url", forKey: .type)
            try container.encode(ImageURLBox(url: url), forKey: .imageURL)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Key.self)
        switch try container.decode(String.self, forKey: .type) {
        case "text":
            self = .text(try container.decode(String.self, forKey: .text))
        case "image_url":
            self = .imageURL(try container.decode(ImageURLBox.self, forKey: .imageURL).url)
        case let other:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: container,
                debugDescription: "unknown content part type \(other)")
        }
    }
}

/// The injection seam the resolver depends on. Mirrors the TS `client.chat.completions.parse`
/// shape: given a model + messages, return the Worker's `{ choices }` completion.
protocol NextToolCallClient: Sendable {
    func completeNextToolCall(
        model: String,
        messages: [ChatMessage]
    ) async throws -> NextToolCallCompletion
}

/// The Worker's response envelope — `{ choices: [...] }` (the OpenAI `chat.completions`
/// choices the Worker forwards). Only the fields the resolver reads are modeled.
struct NextToolCallCompletion: Decodable, Sendable, Equatable {
    let choices: [Choice]

    struct Choice: Decodable, Sendable, Equatable {
        let finishReason: String?
        let message: Message

        private enum Key: String, CodingKey {
            case finishReason = "finish_reason"
            case message
        }

        init(finishReason: String?, message: Message) {
            self.finishReason = finishReason
            self.message = message
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Key.self)
            finishReason = try c.decodeIfPresent(String.self, forKey: .finishReason)
            message = try c.decode(Message.self, forKey: .message)
        }
    }

    /// The completion message: the structured-output `parsed` payload (a `NextToolCall`) or a
    /// `refusal` string. Both optional — a truncated/empty completion carries neither.
    struct Message: Decodable, Sendable, Equatable {
        let parsed: NextToolCall?
        let refusal: String?

        init(parsed: NextToolCall?, refusal: String?) {
            self.parsed = parsed
            self.refusal = refusal
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Key.self)
            parsed = try c.decodeIfPresent(NextToolCall.self, forKey: .parsed)
            refusal = try c.decodeIfPresent(String.self, forKey: .refusal)
        }

        private enum Key: String, CodingKey { case parsed, refusal }
    }

    init(choices: [Choice]) {
        self.choices = choices
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        choices = try c.decode([Choice].self, forKey: .choices)
    }

    private enum Key: String, CodingKey { case choices }
}

/// Typed Worker-client failures. Each maps to the resolver's `blocked` arm with a clean
/// message (the resolver prefixes "Intent resolver failed: …").
enum IntentWorkerError: Error, Equatable, CustomStringConvertible {
    case invalidConfiguration(String)
    case missingCredentials(String)
    case providerUnavailable(String)
    /// An inline image part's base64 payload exceeded `ContentPart.maxImageBase64Bytes` — the
    /// message is rejected before it can become a malformed/oversized provider request.
    case imageTooLarge(String)

    var description: String {
        switch self {
        case let .invalidConfiguration(message),
             let .missingCredentials(message),
             let .providerUnavailable(message),
             let .imageTooLarge(message):
            return message
        }
    }
}

/// The live Worker client. Holds only the Worker URL + the app-cohort token; the OpenAI key
/// stays server-side. HTTPS-only and query/fragment-free, matching `SpeechService`'s boundary.
struct IntentWorkerClient: NextToolCallClient {
    let endpoint: URL
    let authorization: String
    private let transport: Transport

    /// The HTTP transport seam — defaults to `URLSession`; a test can substitute a recorder.
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    /// Build a client from a Worker base URL (e.g. `https://intent.example.workers.dev`) and
    /// the app-cohort token. The resolve path is appended; the base URL must be HTTPS and carry
    /// no query/fragment. Throws `invalidConfiguration`/`missingCredentials` on a bad input.
    init(
        workerURL: String,
        appToken: String,
        transport: @escaping Transport = IntentWorkerClient.defaultTransport
    ) throws {
        self.endpoint = try IntentWorkerClient.resolveEndpoint(workerURL)
        let token = appToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            throw IntentWorkerError.missingCredentials(
                "missing-credentials: intent Worker app token is empty")
        }
        self.authorization = "Bearer \(token)"
        self.transport = transport
    }

    /// The Worker resolve path (workers/llm-intent only serves this route).
    static let resolvePath = "/v1/resolve-intent"

    static func resolveEndpoint(_ workerURL: String) throws -> URL {
        guard var components = URLComponents(
            string: workerURL.trimmingCharacters(in: .whitespacesAndNewlines)),
            let scheme = components.scheme,
            let host = components.host, !host.isEmpty
        else {
            throw IntentWorkerError.invalidConfiguration(
                "invalid-configuration: intent Worker URL must be a valid URL")
        }
        guard scheme == "https" else {
            throw IntentWorkerError.invalidConfiguration(
                "invalid-configuration: intent Worker URL must use https")
        }
        guard components.query == nil, components.fragment == nil else {
            throw IntentWorkerError.invalidConfiguration(
                "invalid-configuration: intent Worker URL must not include query or fragment")
        }
        // The Worker only serves `/v1/resolve-intent`. `.env.local` (and the prior Rust client)
        // carry the FULL endpoint URL, used as-is; a bare origin is also accepted. Append the route
        // only when it is not already present, so a full URL is never doubled into
        // `/v1/resolve-intent/v1/resolve-intent` (the cause of the Worker's HTTP 404).
        let basePath = components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path
        components.path = basePath.hasSuffix(resolvePath) ? basePath : basePath + resolvePath
        guard let url = components.url else {
            throw IntentWorkerError.invalidConfiguration(
                "invalid-configuration: intent Worker URL must be a valid URL")
        }
        return url
    }

    /// Build the POST request the resolver sends — `{ model, messages }` JSON with the app
    /// Bearer token. Exposed so a test can assert the on-the-wire shape without a live Worker.
    func makeRequest(model: String, messages: [ChatMessage]) throws -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body = IntentRequestBody(model: model, messages: messages)
        request.httpBody = try JSONEncoder().encode(body)
        return request
    }

    func completeNextToolCall(
        model: String,
        messages: [ChatMessage]
    ) async throws -> NextToolCallCompletion {
        let request = try makeRequest(model: model, messages: messages)
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await transport(request)
        } catch {
            throw IntentWorkerError.providerUnavailable(
                "provider-unavailable: \(error.localizedDescription)")
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw IntentWorkerError.providerUnavailable(
                "provider-unavailable: intent Worker returned HTTP \(http.statusCode)")
        }
        do {
            return try JSONDecoder().decode(NextToolCallCompletion.self, from: data)
        } catch {
            throw IntentWorkerError.providerUnavailable(
                "provider-unavailable: intent Worker returned an undecodable completion")
        }
    }

    /// The wire body the Worker's `parseIntentRequest` reads.
    private struct IntentRequestBody: Encodable {
        let model: String
        let messages: [ChatMessage]
    }

    static let defaultTransport: Transport = { request in
        try await URLSession.shared.data(for: request)
    }
}
