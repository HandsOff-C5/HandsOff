//
//  AgentReplay.swift
//  DirectorSidecar
//
//  Agent Replay is the raw, support/debug reconstruction stream for Director runs. It is separate
//  from Observability on purpose: observability stays sanitized metrics/spans, while Agent Replay
//  may carry raw transcripts, prompts, model responses, tool args/results, approvals, and terminal
//  statuses. The app still never holds Langfuse credentials; it only posts append-only replay events
//  to the Worker, which performs the server-side Langfuse write.
//

import Foundation
import OSLog

enum AgentReplayEventType: String, Codable, Sendable, CaseIterable {
    case sessionStarted = "session_started"
    case transcriptFinal = "transcript_final"
    case promptBuilt = "prompt_built"
    case modelResponse = "model_response"
    case intentResolved = "intent_resolved"
    case approvalDecided = "approval_decided"
    case toolCallStarted = "tool_call_started"
    case toolCallFinished = "tool_call_finished"
    case loopFinished = "loop_finished"
    case loopFailed = "loop_failed"
}

enum AgentReplayPrivacyError: Error, Equatable, LocalizedError {
    case emptyField(String)
    case invalidTimestamp(String)
    case nonFiniteNumber(String)
    case forbiddenPayloadKey(String)
    case forbiddenPayloadValue(String)

    var errorDescription: String? {
        switch self {
        case let .emptyField(field): return "Agent Replay field must not be empty: \(field)"
        case let .invalidTimestamp(value): return "Agent Replay timestamp is not ISO-8601: \(value)"
        case let .nonFiniteNumber(path): return "Agent Replay number must be finite: \(path)"
        case let .forbiddenPayloadKey(path): return "Agent Replay payload contains an excluded key: \(path)"
        case let .forbiddenPayloadValue(path): return "Agent Replay payload contains an excluded value: \(path)"
        }
    }
}

struct AgentReplayEvent: Codable, Equatable, Sendable, Identifiable {
    let sessionId: String
    let seq: Int
    let eventId: String
    let type: AgentReplayEventType
    let timestamp: String
    let payload: Contracts.JSONValue

    var id: String { eventId }

    init(
        sessionId: String,
        seq: Int,
        eventId: String,
        type: AgentReplayEventType,
        timestamp: String,
        payload: Contracts.JSONValue
    ) throws {
        let cleanedSessionId = sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedEventId = eventId.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedTimestamp = timestamp.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedSessionId.isEmpty else { throw AgentReplayPrivacyError.emptyField("sessionId") }
        guard seq >= 0 else { throw AgentReplayPrivacyError.emptyField("seq") }
        guard !cleanedEventId.isEmpty else { throw AgentReplayPrivacyError.emptyField("eventId") }
        guard Self.isISODateTime(cleanedTimestamp) else {
            throw AgentReplayPrivacyError.invalidTimestamp(cleanedTimestamp)
        }
        try Self.validatePayload(payload)
        self.sessionId = cleanedSessionId
        self.seq = seq
        self.eventId = cleanedEventId
        self.type = type
        self.timestamp = cleanedTimestamp
        self.payload = payload
    }

    private static func isISODateTime(_ value: String) -> Bool {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if formatter.date(from: value) != nil { return true }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value) != nil
    }

    private static func validatePayload(_ value: Contracts.JSONValue, path: String = "payload") throws {
        switch value {
        case .null, .bool:
            return
        case let .number(number):
            guard number.isFinite else { throw AgentReplayPrivacyError.nonFiniteNumber(path) }
        case let .string(string):
            if string.range(
                of: #"\bbearer\s+[a-z0-9._~+/=-]+"#,
                options: [.regularExpression, .caseInsensitive]
            ) != nil {
                throw AgentReplayPrivacyError.forbiddenPayloadValue(path)
            }
        case let .array(values):
            for (index, item) in values.enumerated() {
                try validatePayload(item, path: "\(path)[\(index)]")
            }
        case let .object(fields):
            for (key, item) in fields {
                let nestedPath = "\(path).\(key)"
                if forbiddenPayloadKey(key) {
                    throw AgentReplayPrivacyError.forbiddenPayloadKey(nestedPath)
                }
                try validatePayload(item, path: nestedPath)
            }
        }
    }

    private static func forbiddenPayloadKey(_ key: String) -> Bool {
        let normalized = key.lowercased().filter { $0.isLetter || $0.isNumber }
        if normalized == "authorization" || normalized == "token" { return true }
        return [
            "credential",
            "providerkey",
            "apikey",
            "appauthtoken",
            "bearertoken",
            "bearer",
            "cookie",
            "password",
            "secret",
            "screenshot",
            "pixel",
            "rawaudio",
            "rawvideo",
            "audioframe",
            "videoframe",
        ].contains { normalized.contains($0) }
    }
}

struct AgentReplayBufferSnapshot: Codable, Equatable, Sendable {
    var nextSeqBySession: [String: Int] = [:]
    var pendingEvents: [AgentReplayEvent] = []
}

@MainActor
final class AgentReplayStore {
    private let url: URL
    private let fileManager: FileManager
    private var cached: AgentReplayBufferSnapshot

    init(url: URL, fileManager: FileManager = .default) {
        self.url = url
        self.fileManager = fileManager
        guard fileManager.fileExists(atPath: url.path) else {
            cached = AgentReplayBufferSnapshot()
            return
        }
        do {
            let data = try Data(contentsOf: url)
            cached = try JSONDecoder().decode(AgentReplayBufferSnapshot.self, from: data)
        } catch {
            let backup = url.deletingPathExtension()
                .appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970)).json")
            try? fileManager.moveItem(at: url, to: backup)
            cached = AgentReplayBufferSnapshot()
        }
    }

    static func applicationSupport(fileManager: FileManager = .default) -> AgentReplayStore {
        let directory = try! fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("Director", isDirectory: true)
        return AgentReplayStore(url: directory.appendingPathComponent("agent-replay-buffer.json"))
    }

    func snapshot() -> AgentReplayBufferSnapshot { cached }

    func pendingEvents() -> [AgentReplayEvent] { cached.pendingEvents }

    @discardableResult
    func append(
        sessionId: String,
        type: AgentReplayEventType,
        timestamp: String,
        payload: Contracts.JSONValue
    ) throws -> AgentReplayEvent {
        let seq = cached.nextSeqBySession[sessionId] ?? 0
        let event = try AgentReplayEvent(
            sessionId: sessionId,
            seq: seq,
            eventId: "\(sessionId):\(seq):\(type.rawValue)",
            type: type,
            timestamp: timestamp,
            payload: payload
        )
        cached.nextSeqBySession[sessionId] = seq + 1
        cached.pendingEvents.append(event)
        persist()
        return event
    }

    func markAccepted(eventIds: [String]) {
        guard !eventIds.isEmpty else { return }
        let accepted = Set(eventIds)
        cached.pendingEvents.removeAll { accepted.contains($0.eventId) }
        persist()
    }

    private func persist() {
        do {
            try fileManager.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(cached)
            try data.write(to: url, options: .atomic)
        } catch {
            DirectorDiagnostics.loop.error(
                "agent replay persist failed error=\(String(reflecting: type(of: error)), privacy: .public)"
            )
            assertionFailure("Unable to persist Agent Replay buffer")
        }
    }
}

protocol AgentReplaySending: Sendable {
    func send(_ events: [AgentReplayEvent]) async throws -> AgentReplayWorkerResponse
}

struct AgentReplayAcceptedEvent: Codable, Equatable, Sendable {
    let eventId: String
    let sessionId: String
    let seq: Int
}

struct AgentReplayWorkerResponse: Codable, Equatable, Sendable {
    let accepted: [AgentReplayAcceptedEvent]
    let duplicateEventIds: [String]
}

enum AgentReplayWorkerError: Error, Equatable, CustomStringConvertible {
    case invalidConfiguration(String)
    case missingCredentials(String)
    case deliveryFailed(String)

    var description: String {
        switch self {
        case let .invalidConfiguration(message),
             let .missingCredentials(message),
             let .deliveryFailed(message):
            return message
        }
    }
}

struct AgentReplayWorkerClient: AgentReplaySending {
    let endpoint: URL
    let authorization: String
    private let transport: Transport

    typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    static let eventsPath = "/v1/agent-replay/events"

    init(
        workerURL: String,
        appToken: String,
        transport: @escaping Transport = AgentReplayWorkerClient.defaultTransport
    ) throws {
        self.endpoint = try Self.resolveEndpoint(workerURL)
        let token = appToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            throw AgentReplayWorkerError.missingCredentials(
                "missing-credentials: Agent Replay Worker app token is empty")
        }
        self.authorization = "Bearer \(token)"
        self.transport = transport
    }

    static func resolveEndpoint(_ workerURL: String) throws -> URL {
        guard var components = URLComponents(
            string: workerURL.trimmingCharacters(in: .whitespacesAndNewlines)),
            let scheme = components.scheme,
            let host = components.host, !host.isEmpty
        else {
            throw AgentReplayWorkerError.invalidConfiguration(
                "invalid-configuration: Agent Replay Worker URL must be a valid URL")
        }
        guard scheme == "https" else {
            throw AgentReplayWorkerError.invalidConfiguration(
                "invalid-configuration: Agent Replay Worker URL must use https")
        }
        guard components.query == nil, components.fragment == nil else {
            throw AgentReplayWorkerError.invalidConfiguration(
                "invalid-configuration: Agent Replay Worker URL must not include query or fragment")
        }
        let basePath = components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path
        components.path = basePath.hasSuffix(eventsPath) ? basePath : basePath + eventsPath
        guard let url = components.url else {
            throw AgentReplayWorkerError.invalidConfiguration(
                "invalid-configuration: Agent Replay Worker URL must be a valid URL")
        }
        return url
    }

    func makeRequest(events: [AgentReplayEvent]) throws -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(AgentReplayWorkerRequest(events: events))
        return request
    }

    func send(_ events: [AgentReplayEvent]) async throws -> AgentReplayWorkerResponse {
        guard !events.isEmpty else {
            return AgentReplayWorkerResponse(accepted: [], duplicateEventIds: [])
        }
        let request = try makeRequest(events: events)
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await transport(request)
        } catch {
            throw AgentReplayWorkerError.deliveryFailed(
                "delivery-failed: \(error.localizedDescription)")
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw AgentReplayWorkerError.deliveryFailed(
                "delivery-failed: Agent Replay Worker returned HTTP \(http.statusCode)")
        }
        do {
            return try JSONDecoder().decode(AgentReplayWorkerResponse.self, from: data)
        } catch {
            throw AgentReplayWorkerError.deliveryFailed(
                "delivery-failed: Agent Replay Worker returned an undecodable response")
        }
    }

    private struct AgentReplayWorkerRequest: Encodable {
        let events: [AgentReplayEvent]
    }

    static let defaultTransport: Transport = { request in
        try await URLSession.shared.data(for: request)
    }
}

enum AgentReplayWorkerConfig {
    static let workerURLKey = "HANDSOFF_AGENT_REPLAY_WORKER_URL"
    static let appTokenKey = "HANDSOFF_AGENT_REPLAY_APP_AUTH_TOKEN"

    static func client(
        env: [String: String] = ProcessInfo.processInfo.environment,
        bundle: Bundle = .main
    ) -> AgentReplayWorkerClient? {
        guard let url = IntentWorkerConfig.value(workerURLKey, env: env, bundle: bundle),
              let token = IntentWorkerConfig.value(appTokenKey, env: env, bundle: bundle),
              let client = try? AgentReplayWorkerClient(workerURL: url, appToken: token) else {
            return nil
        }
        return client
    }
}

@MainActor
protocol AgentReplayRecording: AnyObject, Sendable {
    @discardableResult
    func record(
        sessionId: String,
        type: AgentReplayEventType,
        timestamp: String?,
        payload: Contracts.JSONValue
    ) -> AgentReplayEvent?
}

@MainActor
final class AgentReplayEmitter: AgentReplayRecording {
    private let store: AgentReplayStore
    private let sender: (any AgentReplaySending)?
    private let clock: @Sendable () -> String
    private let autoFlush: Bool
    private var flushing = false

    init(
        store: AgentReplayStore,
        sender: (any AgentReplaySending)? = nil,
        autoFlush: Bool = true,
        clock: @escaping @Sendable () -> String = { AgentReplayEmitter.timestamp() }
    ) {
        self.store = store
        self.sender = sender
        self.autoFlush = autoFlush
        self.clock = clock
    }

    @discardableResult
    func record(
        sessionId: String,
        type: AgentReplayEventType,
        timestamp: String? = nil,
        payload: Contracts.JSONValue
    ) -> AgentReplayEvent? {
        do {
            let event = try store.append(
                sessionId: sessionId,
                type: type,
                timestamp: timestamp ?? clock(),
                payload: payload
            )
            if autoFlush { flushSoon() }
            return event
        } catch {
            DirectorDiagnostics.loop.error("agent replay record rejected type=\(type.rawValue, privacy: .public) error=\(String(describing: error), privacy: .public)")
            return nil
        }
    }

    func pendingEvents() -> [AgentReplayEvent] { store.pendingEvents() }

    func flushSoon() {
        guard sender != nil else { return }
        Task { @MainActor [weak self] in
            await self?.flushPending()
        }
    }

    func flushPending() async {
        guard !flushing, let sender else { return }
        let events = store.pendingEvents()
        guard !events.isEmpty else { return }
        flushing = true
        var shouldFlushAgain = false
        do {
            let response = try await sender.send(events)
            store.markAccepted(
                eventIds: response.accepted.map(\.eventId) + response.duplicateEventIds)
            shouldFlushAgain = !store.pendingEvents().isEmpty
        } catch {
            DirectorDiagnostics.loop.error("agent replay flush failed error=\(String(reflecting: type(of: error)), privacy: .public)")
        }
        flushing = false
        if shouldFlushAgain { flushSoon() }
    }

    nonisolated static func timestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }
}

extension Contracts.JSONValue {
    static func replayEncoded<T: Encodable>(_ value: T) -> Contracts.JSONValue {
        guard let data = try? JSONEncoder().encode(value),
              let decoded = try? JSONDecoder().decode(Contracts.JSONValue.self, from: data) else {
            return .string(String(describing: value))
        }
        return decoded
    }
}
