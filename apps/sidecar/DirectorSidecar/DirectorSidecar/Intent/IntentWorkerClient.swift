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
struct NextToolCallCompletion: Codable, Sendable, Equatable {
    let choices: [Choice]

    struct Choice: Codable, Sendable, Equatable {
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
    struct Message: Codable, Sendable, Equatable {
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

    var description: String {
        switch self {
        case let .invalidConfiguration(message),
             let .missingCredentials(message),
             let .providerUnavailable(message):
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
