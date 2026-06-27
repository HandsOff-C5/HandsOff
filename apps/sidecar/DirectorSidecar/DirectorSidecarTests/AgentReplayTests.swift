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

private func replayPayloadObject(_ value: Contracts.JSONValue) throws -> [String: Contracts.JSONValue] {
    guard case let .object(fields) = value else {
        Issue.record("expected object payload")
        return [:]
    }
    return fields
}

private func replayPayloadArray(_ value: Contracts.JSONValue) throws -> [Contracts.JSONValue] {
    guard case let .array(values) = value else {
        Issue.record("expected array payload")
        return []
    }
    return values
}

private func replayPayloadJSONString(_ value: Contracts.JSONValue) throws -> String {
    let data = try JSONEncoder().encode(value)
    return String(decoding: data, as: UTF8.self)
}

@MainActor
struct AgentReplayStoreTests {
    @Test func persistsPendingEventsAndContinuesStableSeqAfterRestart() async throws {
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

        await store.flushPersistence()
        let restored = AgentReplayStore(url: url)
        #expect(restored.pendingEvents() == [first, second])
        restored.markAccepted(eventIds: [first.eventId])
        #expect(restored.pendingEvents() == [second])
        await restored.flushPersistence()
        #expect(AgentReplayStore(url: url).pendingEvents() == [second])

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

struct AgentReplayPayloadTests {
    @Test func redactsInputArgsFromIntentAndToolCallReplayPayloads() throws {
        let surface = #"""
        {"id":"surface-1","title":"Checkout","app":"Notes","pid":321,"windowId":654,"availability":"available","accessStatus":"accessible"}
        """#
        let intentJSON = #"""
        {
          "status":"ready",
          "id":"intent-1",
          "input":{
            "sessionId":"session-1",
            "speech":{"finalTranscript":{"kind":"final","text":"type the code","confidence":0.95,"latencyMs":100,"receivedAt":1}},
            "pointingEvidence":[],
            "surfaceCandidates":[\#(surface)]
          },
          "intent_type":"type_text",
          "referent":null,
          "constraints":[],
          "risk_level":"reversible",
          "requires_approval":false,
          "target_agent":"cua-driver",
          "action_plan":{
            "id":"plan-1",
            "summary":"Fill the form",
            "risk_level":"reversible",
            "requires_approval":false,
            "target_agent":"cua-driver",
            "action_plan":[
              {"id":"s1","label":"Type code","kind":"type_text","target":{"surface":\#(surface),"elementIndex":7},"text":"hunter2-code"},
              {"id":"s2","label":"Set card","kind":"set_value","target":{"surface":\#(surface),"elementIndex":8},"value":"4111111111111111"}
            ]
          },
          "createdAt":"\#(replayTimestamp)"
        }
        """#
        let intent = try JSONDecoder().decode(Contracts.ResolvedIntent.self, from: Data(intentJSON.utf8))

        let resolved = AgentReplayPayloads.intent(intent, tick: 0, durationMs: 12)
        let resolvedFields = try replayPayloadObject(resolved)
        let toolCalls = try replayPayloadArray(try #require(resolvedFields["toolCalls"]))
        let typeCall = try replayPayloadObject(toolCalls[0])
        let typeArgs = try replayPayloadObject(try #require(typeCall["args"]))
        let setCall = try replayPayloadObject(toolCalls[1])
        let setArgs = try replayPayloadObject(try #require(setCall["args"]))

        #expect(typeArgs["text"] == nil)
        #expect(typeArgs["inputLength"] == .number(12))
        #expect(typeArgs["element_index"] == .number(7))
        #expect(setArgs["value"] == nil)
        #expect(setArgs["inputLength"] == .number(16))
        #expect(setArgs["element_index"] == .number(8))

        let started = AgentReplayPayloads.toolCallStarted(
            tool: "type_text",
            args: ["element_index": .number(7), "text": .string("hunter2-code")]
        )
        let startedArgs = try replayPayloadObject(try #require(replayPayloadObject(started)["args"]))
        #expect(startedArgs["text"] == nil)
        #expect(startedArgs["inputLength"] == .number(12))

        let finished = AgentReplayPayloads.toolCallFinished(
            tool: "set_value",
            args: ["element_index": .number(8), "value": .string("4111111111111111")],
            result: .succeeded(
                summary: "Called set_value",
                state: Contracts.CuaWindowState(
                    surface: Contracts.SurfaceSnapshot(
                        id: "surface-1",
                        title: "Checkout",
                        app: "Notes",
                        pid: 321,
                        windowId: 654,
                        availability: .available,
                        accessStatus: .accessible
                    ),
                    capturedAt: replayTimestamp,
                    elementCount: 1,
                    elements: [
                        Contracts.CuaElement(
                            id: "field-1",
                            index: 8,
                            role: "AXTextField",
                            label: "Card",
                            value: "4111111111111111"
                        ),
                    ]
                )
            ),
            status: "succeeded"
        )
        let finishedFields = try replayPayloadObject(finished)
        let finishedArgs = try replayPayloadObject(try #require(finishedFields["args"]))
        #expect(finishedArgs["value"] == nil)
        #expect(finishedArgs["inputLength"] == .number(16))
        let finishedResult = try replayPayloadObject(try #require(finishedFields["result"]))
        let finishedState = try replayPayloadObject(try #require(finishedResult["state"]))
        let finishedElements = try replayPayloadArray(try #require(finishedState["elements"]))
        let finishedElement = try replayPayloadObject(try #require(finishedElements.first))
        #expect(finishedElement["value"] == nil)
        #expect(finishedElement["valueLength"] == .number(16))

        let replayJSON = try [
            resolved,
            started,
            finished,
        ].map(replayPayloadJSONString).joined(separator: "\n")
        #expect(!replayJSON.contains("hunter2-code"))
        #expect(!replayJSON.contains("4111111111111111"))
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
