//
//  AgentReplayTests.swift
//  DirectorSidecarTests
//

import Testing
import Foundation
@testable import DirectorSidecar

private let replayTimestamp = "2026-06-27T15:00:00.000Z"

private enum ReplayTestError: Error {
    case delivery
}

private actor FakeReplaySender: AgentReplaySending {
    private var failuresRemaining: Int
    private let duplicateIds: [String]
    private var batches: [[AgentReplayEvent]] = []

    init(failuresRemaining: Int = 0, duplicateIds: [String] = []) {
        self.failuresRemaining = failuresRemaining
        self.duplicateIds = duplicateIds
    }

    func send(_ events: [AgentReplayEvent]) async throws -> AgentReplayWorkerResponse {
        batches.append(events)
        if failuresRemaining > 0 {
            failuresRemaining -= 1
            throw ReplayTestError.delivery
        }
        let duplicateSet = Set(duplicateIds)
        return AgentReplayWorkerResponse(
            accepted: events
                .filter { !duplicateSet.contains($0.eventId) }
                .map { AgentReplayAcceptedEvent(eventId: $0.eventId, sessionId: $0.sessionId, seq: $0.seq) },
            duplicateEventIds: duplicateIds
        )
    }

    func sentBatches() -> [[AgentReplayEvent]] { batches }
}

private struct ReplayResolverClient: NextToolCallClient {
    let completion: NextToolCallCompletion

    func completeNextToolCall(model: String, messages: [ChatMessage]) async throws -> NextToolCallCompletion {
        completion
    }
}

private func tempReplayURL(_ name: String = "agent-replay-buffer.json") -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("DirectorSidecarTests-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent(name)
}

private func replayPayload(_ text: String = "value") -> Contracts.JSONValue {
    .object(["text": .string(text)])
}

private func replayEvent(
    seq: Int = 0,
    type: AgentReplayEventType = .sessionStarted
) throws -> AgentReplayEvent {
    try AgentReplayEvent(
        sessionId: "session-1",
        seq: seq,
        eventId: "session-1:\(seq):\(type.rawValue)",
        type: type,
        timestamp: replayTimestamp,
        payload: replayPayload()
    )
}

private func finalTranscript(_ text: String) -> Contracts.FinalTranscript {
    let json = #"{"kind":"final","text":"\#(text)","confidence":0.95,"latencyMs":100,"receivedAt":1}"#
    return try! JSONDecoder().decode(Contracts.FinalTranscript.self, from: Data(json.utf8))
}

private func replayInput(_ text: String = "scroll") -> Contracts.IntentInput {
    Contracts.IntentInput(
        sessionId: "session-1",
        finalTranscript: finalTranscript(text),
        pointingEvidence: [],
        surfaceCandidates: [],
        goalSession: nil
    )
}

@MainActor
struct AgentReplayStoreTests {
    @Test func persistsPendingEventsAndContinuesStableSeqAfterRestart() throws {
        let url = tempReplayURL()
        let store = AgentReplayStore(url: url)
        let first = try store.append(
            sessionId: "session-1",
            type: .sessionStarted,
            timestamp: replayTimestamp,
            payload: replayPayload("started")
        )
        let second = try store.append(
            sessionId: "session-1",
            type: .transcriptFinal,
            timestamp: replayTimestamp,
            payload: replayPayload("transcript")
        )

        #expect(first.seq == 0)
        #expect(first.eventId == "session-1:0:session_started")
        #expect(second.seq == 1)
        #expect(second.eventId == "session-1:1:transcript_final")

        let restored = AgentReplayStore(url: url)
        #expect(restored.pendingEvents() == [first, second])
        restored.markAccepted(eventIds: [first.eventId])
        #expect(restored.pendingEvents() == [second])

        let third = try restored.append(
            sessionId: "session-1",
            type: .loopFinished,
            timestamp: replayTimestamp,
            payload: replayPayload("finished")
        )
        #expect(third.seq == 2)
        #expect(third.eventId == "session-1:2:loop_finished")
    }

    @Test func rejectsExcludedReplayPayloadKeysBeforeBuffering() {
        #expect(throws: AgentReplayPrivacyError.forbiddenPayloadKey("payload.args.bearerToken")) {
            _ = try AgentReplayEvent(
                sessionId: "session-1",
                seq: 0,
                eventId: "event-1",
                type: .toolCallStarted,
                timestamp: replayTimestamp,
                payload: .object([
                    "args": .object(["bearerToken": .string("should-not-store")]),
                ])
            )
        }
    }
}

@MainActor
struct AgentReplayEmitterTests {
    @Test func keepsPendingEventsAfterFailedFlushThenCompactsAfterAck() async {
        let sender = FakeReplaySender(failuresRemaining: 1)
        let emitter = AgentReplayEmitter(
            store: AgentReplayStore(url: tempReplayURL()),
            sender: sender,
            autoFlush: false,
            clock: { replayTimestamp }
        )

        let recorded = emitter.record(
            sessionId: "session-1",
            type: .sessionStarted,
            payload: replayPayload("started")
        )
        #expect(recorded?.eventId == "session-1:0:session_started")

        await emitter.flushPending()
        #expect(emitter.pendingEvents().map(\.eventId) == ["session-1:0:session_started"])

        await emitter.flushPending()
        #expect(emitter.pendingEvents().isEmpty)
        #expect(await sender.sentBatches().count == 2)
    }

    @Test func duplicateAckCompactsRetryBufferWithoutRewritingSeq() async throws {
        let event = try replayEvent()
        let sender = FakeReplaySender(duplicateIds: [event.eventId])
        let emitter = AgentReplayEmitter(
            store: AgentReplayStore(url: tempReplayURL()),
            sender: sender,
            autoFlush: false,
            clock: { replayTimestamp }
        )
        _ = emitter.record(sessionId: event.sessionId, type: event.type, payload: event.payload)

        await emitter.flushPending()

        #expect(emitter.pendingEvents().isEmpty)
        #expect(await sender.sentBatches().first?.map(\.eventId) == [event.eventId])
    }
}

struct AgentReplayWorkerClientTests {
    @Test func buildsPostWithAppTokenAndReplayEventsPath() throws {
        let event = try replayEvent()
        let client = try AgentReplayWorkerClient(
            workerURL: "https://replay.example.workers.dev",
            appToken: "app-tok"
        )
        let request = try client.makeRequest(events: [event])

        #expect(request.url?.absoluteString == "https://replay.example.workers.dev/v1/agent-replay/events")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer app-tok")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")

        struct Body: Decodable { let events: [AgentReplayEvent] }
        let body = try JSONDecoder().decode(Body.self, from: #require(request.httpBody))
        #expect(body.events == [event])
    }

    @Test func rejectsNonHttpsAndEmptyToken() {
        #expect(throws: AgentReplayWorkerError.self) {
            _ = try AgentReplayWorkerClient(workerURL: "http://replay.example.workers.dev", appToken: "app-tok")
        }
        #expect(throws: AgentReplayWorkerError.self) {
            _ = try AgentReplayWorkerClient(workerURL: "https://replay.example.workers.dev", appToken: "  ")
        }
    }

    @Test func decodesAcceptedAndDuplicateAcksFromWorker() async throws {
        let event = try replayEvent()
        let endpoint = URL(string: "https://replay.example.workers.dev/v1/agent-replay/events")!
        let response = #"""
        {"accepted":[{"eventId":"session-1:0:session_started","sessionId":"session-1","seq":0}],"duplicateEventIds":["session-1:9:loop_finished"]}
        """#
        let client = try AgentReplayWorkerClient(
            workerURL: "https://replay.example.workers.dev",
            appToken: "app-tok"
        ) { _ in
            (
                Data(response.utf8),
                HTTPURLResponse(url: endpoint, statusCode: 200, httpVersion: nil, headerFields: nil)!
            )
        }

        let ack = try await client.send([event])

        #expect(ack.accepted == [
            AgentReplayAcceptedEvent(eventId: event.eventId, sessionId: event.sessionId, seq: event.seq),
        ])
        #expect(ack.duplicateEventIds == ["session-1:9:loop_finished"])
    }
}

@MainActor
struct AgentReplayResolverGoldenTests {
    @Test func capturesPromptAndModelResponseForWorkerResolverCall() async {
        let parsed = NextToolCall(
            status: .done,
            tool: nil,
            args: nil,
            rationale: "done",
            summary: "Already complete",
            reason: nil
        )
        let completion = NextToolCallCompletion(choices: [
            .init(finishReason: "stop", message: .init(parsed: parsed, refusal: nil)),
        ])
        let emitter = AgentReplayEmitter(
            store: AgentReplayStore(url: tempReplayURL()),
            autoFlush: false,
            clock: { replayTimestamp }
        )

        let resolved = await NextToolCallResolver.resolveNextToolCall(
            replayInput("already done"),
            client: ReplayResolverClient(completion: completion),
            tools: [],
            model: "gpt-4o-mini",
            createdAt: replayTimestamp,
            replay: emitter
        )

        guard case .satisfied = resolved else {
            Issue.record("expected satisfied resolver result")
            return
        }
        let events = emitter.pendingEvents()
        #expect(events.map(\.type) == [.promptBuilt, .modelResponse])
        #expect(events.map(\.eventId) == [
            "session-1:0:prompt_built",
            "session-1:1:model_response",
        ])
        guard case let .object(promptPayload) = events[0].payload,
              case let .object(modelPayload) = events[1].payload else {
            Issue.record("expected object replay payloads")
            return
        }
        #expect(promptPayload["model"] == .string("gpt-4o-mini"))
        #expect(promptPayload["toolCatalogSize"] == .number(0))
        #expect(promptPayload["messages"] != nil)
        #expect(modelPayload["model"] == .string("gpt-4o-mini"))
        #expect(modelPayload["completion"] != nil)
    }
}
