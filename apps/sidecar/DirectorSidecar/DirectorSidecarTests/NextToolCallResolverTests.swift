//
//  NextToolCallResolverTests.swift
//  DirectorSidecarTests
//
//  Port of @handsoff/intent src/llm/next-tool-call.test.ts (resolver + mapping + prompt) plus
//  Contracts.ToolRisk unit coverage (tool-risk.ts) and the IntentWorkerClient provider-boundary
//  wire shape. Every input is real TS-shaped JSON decoded through `Contracts.IntentInput`, and
//  the model decisions are injected through a stub `NextToolCallClient` — no network, no mocks
//  of the resolver itself. Output is the canonical `Contracts.ResolvedIntent` the loop consumes.
//

import Testing
import Foundation
@testable import DirectorSidecar

// MARK: - Fixtures

private func surfaceDict(
    id: String = "notes:1", title: String = "Quick Note", app: String = "Notes",
    pid: Int? = 42, windowId: Int? = 7,
    availability: String = "available", accessStatus: String = "accessible"
) -> [String: Any] {
    var dict: [String: Any] = [
        "id": id, "title": title, "app": app,
        "availability": availability, "accessStatus": accessStatus,
    ]
    if let pid { dict["pid"] = pid }
    if let windowId { dict["windowId"] = windowId }
    return dict
}

private func makeInput(
    transcript: String = "scroll down to find Boogie Woogie",
    pointingEvidence: [[String: Any]] = [["source": "head", "confidence": 0.9, "strategy": "head-neighborhood"]],
    surfaceCandidates: [[String: Any]] = [surfaceDict()],
    goalSession: [String: Any]? = nil,
    selectionText: String? = nil
) throws -> Contracts.IntentInput {
    var dict: [String: Any] = [
        "sessionId": "session-1",
        "speech": ["finalTranscript": [
            "kind": "final", "text": transcript, "confidence": 0.95, "latencyMs": 100, "receivedAt": 1,
        ]],
        "pointingEvidence": pointingEvidence,
        "surfaceCandidates": surfaceCandidates,
    ]
    if let goalSession { dict["goalSession"] = goalSession }
    if let selectionText { dict["selectionText"] = selectionText }
    let data = try JSONSerialization.data(withJSONObject: dict)
    return try JSONDecoder().decode(Contracts.IntentInput.self, from: data)
}

private func sampleTools() throws -> [DriverToolDefinition] {
    let scrollSchema = try JSONValue.decode(Data(#"""
    {"type":"object","required":["pid","direction"],"properties":{"pid":{"type":"integer"},"direction":{"type":"string"}}}
    """#.utf8))
    return [
        DriverToolDefinition(name: "scroll", description: "Scroll the target pid's focused region.", inputSchema: scrollSchema),
        DriverToolDefinition(name: "get_window_state", description: "Snapshot a window's AX tree.", inputSchema: nil),
    ]
}

private func nextCall(
    status: NextToolCall.Status = .act,
    tool: String? = "scroll",
    args: String? = #"{"pid":42,"window_id":7,"direction":"down","by":"page","amount":3}"#,
    rationale: String = "Scroll the list to reveal hidden rows",
    summary: String? = nil,
    reason: String? = nil
) -> NextToolCall {
    NextToolCall(status: status, tool: tool, args: args, rationale: rationale, summary: summary, reason: reason)
}

/// A stub client returning a canned completion (mirrors the TS `clientWith`). Records the model
/// the resolver passed so the default-model assertion can be made.
private final class StubClient: NextToolCallClient, @unchecked Sendable {
    private let completion: NextToolCallCompletion?
    private let error: Error?
    private(set) var lastModel: String?

    init(_ completion: NextToolCallCompletion) { self.completion = completion; self.error = nil }
    init(throwing error: Error) { self.completion = nil; self.error = error }

    func completeNextToolCall(model: String, messages: [ChatMessage]) async throws -> NextToolCallCompletion {
        lastModel = model
        if let error { throw error }
        return completion!
    }
}

private func completion(_ call: NextToolCall?, finishReason: String? = "stop", refusal: String? = nil) -> NextToolCallCompletion {
    NextToolCallCompletion(choices: [
        .init(finishReason: finishReason, message: .init(parsed: call, refusal: refusal)),
    ])
}

private struct DescribedError: Error, CustomStringConvertible {
    let description: String
}

// MARK: - resolveNextToolCall

@Test func mapsActDecisionToReadyToolCallOverFullSurface() async throws {
    let client = StubClient(completion(nextCall()))
    let resolved = await NextToolCallResolver.resolveNextToolCall(
        try makeInput(), client: client, tools: try sampleTools(), createdAt: "2026-06-22T12:00:00.000Z")

    guard case let .ready(ready) = resolved else { Issue.record("expected ready, got \(resolved)"); return }
    #expect(ready.targetAgent == .cuaDriver)
    #expect(ready.riskLevel == .readOnly)      // scroll is read_only → no approval
    #expect(ready.requiresApproval == false)
    #expect(ready.actionPlan.actionPlan.count == 1)
    guard case let .toolCall(_, _, tool, args) = ready.actionPlan.actionPlan[0] else {
        Issue.record("expected tool_call step"); return
    }
    #expect(tool == .scroll)
    #expect(args["pid"] == .number(42))
    #expect(args["window_id"] == .number(7))
    #expect(args["direction"] == .string("down"))
    #expect(client.lastModel == "gpt-4o")  // default model reaches the Worker (matches worker DEFAULT_OPENAI_MODEL)
}

@Test func usesUnescalatedClickBaseForDisplayIntent() async throws {
    // The display intent carries the click's NAVIGATION base (reversible); the loop stays
    // authoritative and escalates only a proven commit click. Risk is tool-derived, never claimed.
    let client = StubClient(completion(nextCall(tool: "click", args: #"{"pid":42,"window_id":7,"element_index":3}"#)))
    let resolved = await NextToolCallResolver.resolveNextToolCall(try makeInput(), client: client, tools: try sampleTools())

    guard case let .ready(ready) = resolved else { Issue.record("expected ready"); return }
    #expect(ready.riskLevel == .reversible)
    #expect(ready.requiresApproval == false)
}

@Test func blocksHallucinatedToolName() async throws {
    let client = StubClient(completion(nextCall(tool: "format_disk", args: "{}")))
    let resolved = await NextToolCallResolver.resolveNextToolCall(try makeInput(), client: client, tools: try sampleTools())

    guard case let .blocked(pending) = resolved else { Issue.record("expected blocked"); return }
    #expect(pending.reason == "The intent resolver chose an unknown tool: format_disk")
}

@Test func mapsDoneToSatisfiedAndClarifyToClarification() async throws {
    let done = await NextToolCallResolver.resolveNextToolCall(
        try makeInput(),
        client: StubClient(completion(nextCall(status: .done, tool: nil, args: nil, summary: "Found it"))),
        tools: try sampleTools())
    guard case let .satisfied(satisfied) = done else { Issue.record("expected satisfied"); return }
    #expect(satisfied.summary == "Found it")

    let clarify = await NextToolCallResolver.resolveNextToolCall(
        try makeInput(),
        client: StubClient(completion(nextCall(status: .clarify, tool: nil, args: nil, reason: "Which window?"))),
        tools: try sampleTools())
    guard case let .needsClarification(pending) = clarify else { Issue.record("expected clarification"); return }
    #expect(pending.reason == "Which window?")
}

@Test func refusalBecomesClarificationAndErrorBecomesBlocked() async throws {
    let refusal = await NextToolCallResolver.resolveNextToolCall(
        try makeInput(),
        client: StubClient(completion(nil, refusal: "I can't do that.")),
        tools: try sampleTools())
    guard case let .needsClarification(pending) = refusal else { Issue.record("expected clarification"); return }
    #expect(pending.reason == "I can't do that.")

    let blocked = await NextToolCallResolver.resolveNextToolCall(
        try makeInput(),
        client: StubClient(throwing: DescribedError(description: "network down")),
        tools: try sampleTools())
    guard case let .blocked(blockedPending) = blocked else { Issue.record("expected blocked"); return }
    #expect(blockedPending.reason == "Intent resolver failed: network down")
}

@Test func truncatedResponseBecomesClarification() async throws {
    let resolved = await NextToolCallResolver.resolveNextToolCall(
        try makeInput(),
        client: StubClient(completion(nextCall(), finishReason: "length")),
        tools: try sampleTools())
    guard case let .needsClarification(pending) = resolved else { Issue.record("expected clarification"); return }
    #expect(pending.reason == "The intent resolver response was truncated")
}

// MARK: - nextToolCallToIntent (pure mapping)

@Test func defaultsMissingArgsToEmptyObject() throws {
    let resolved = NextToolCallResolver.nextToolCallToIntent(
        nextCall(tool: "list_windows", args: nil), input: try makeInput(), id: "intent-x",
        createdAt: "2026-06-22T12:00:00.000Z")
    guard case let .ready(ready) = resolved, case let .toolCall(_, _, tool, args) = ready.actionPlan.actionPlan[0]
    else { Issue.record("expected ready tool_call"); return }
    #expect(tool == .listWindows)
    #expect(args.isEmpty)
}

@Test func degradesMalformedArgsToEmptyObject() throws {
    let resolved = NextToolCallResolver.nextToolCallToIntent(
        nextCall(tool: "list_windows", args: "{not valid json"), input: try makeInput(), id: "intent-x",
        createdAt: "2026-06-22T12:00:00.000Z")
    guard case let .ready(ready) = resolved, case let .toolCall(_, _, _, args) = ready.actionPlan.actionPlan[0]
    else { Issue.record("expected ready tool_call"); return }
    #expect(args.isEmpty)
}

// MARK: - buildNextToolCallMessages

@Test func sendsGoalSnapshotLoopMemoryCandidatesAndToolMenu() throws {
    let input = try makeInput(goalSession: [
        "goal": "scroll to find Boogie Woogie",
        "tick": 1,
        "observations": [[
            "tick": 1,
            "capturedAt": "2026-06-22T12:00:01.000Z",
            "windows": [surfaceDict()],
            "state": [
                "surface": surfaceDict(),
                "capturedAt": "2026-06-22T12:00:01.000Z",
                "elementCount": 1,
                "elements": [["id": "row-1", "index": 5, "role": "AXRow", "label": "Boogie"]],
            ],
            "previousAction": ["actionId": "intent-x-plan", "result": ["status": "succeeded", "summary": "scrolled"]],
        ]],
    ])
    let messages = NextToolCallPrompt.buildMessages(input, tools: try sampleTools())
    #expect(messages.count == 2)
    #expect(messages[0].role == "system")
    let payload = try parseObject(messages[1].content)

    #expect(payload["goal"] as? String == "scroll to find Boogie Woogie")
    let snapshot = try #require(payload["latestSnapshot"] as? [String: Any])
    let focused = try #require(snapshot["focusedWindow"] as? [String: Any])
    #expect(focused["id"] as? String == "notes:1")
    #expect((focused["pid"] as? NSNumber)?.intValue == 42)
    #expect((focused["windowId"] as? NSNumber)?.intValue == 7)
    let elements = try #require(snapshot["elements"] as? [[String: Any]])
    #expect((elements[0]["index"] as? NSNumber)?.intValue == 5)
    #expect(elements[0]["role"] as? String == "AXRow")
    #expect(elements[0]["label"] as? String == "Boogie")

    let recent = try #require(payload["recentResults"] as? [[String: Any]])
    #expect((recent[0]["tick"] as? NSNumber)?.intValue == 1)
    #expect(recent[0]["status"] as? String == "succeeded")
    #expect(recent[0]["detail"] as? String == "scrolled")

    let tools = try #require(payload["availableTools"] as? [[String: Any]])
    #expect(tools[0]["name"] as? String == "scroll")
    #expect(tools[0]["description"] as? String == "Scroll the target pid's focused region.")
    let scrollParams = try #require(tools[0]["parameters"] as? [String: Any])
    #expect(scrollParams["type"] as? String == "object")
    #expect(scrollParams["required"] as? [String] == ["pid", "direction"])
    // get_window_state has no schema → parameters is null (present-as-null).
    #expect(tools[1]["parameters"] is NSNull)

    // Plain head utterance → empty boundReferents (present, not absent).
    #expect((payload["boundReferents"] as? [Any])?.isEmpty == true)
}

@Test func presentsBoundDeicticReferentsAndPerCandidateConfidence() throws {
    let notes = surfaceDict(id: "win-notes", title: "Notes", app: "Notes")
    let slack = surfaceDict(id: "win-slack", title: "Slack", app: "Slack")
    let input = try makeInput(
        transcript: "type Laura in this and hello in that",
        pointingEvidence: [
            ["source": "fusion", "confidence": 0.85, "strategy": "temporal-bind:this@1100", "surface": notes],
            ["source": "fusion", "confidence": 0.8, "strategy": "temporal-bind:that@5100", "surface": slack],
        ],
        surfaceCandidates: [notes, slack])
    let payload = try parseObject(NextToolCallPrompt.buildMessages(input, tools: try sampleTools())[1].content)

    let bound = try #require(payload["boundReferents"] as? [[String: Any]])
    #expect(bound.count == 2)
    #expect(bound[0]["word"] as? String == "this")
    #expect(bound[0]["surfaceId"] as? String == "win-notes")
    #expect((bound[0]["confidence"] as? NSNumber)?.doubleValue == 0.85)
    #expect(bound[1]["word"] as? String == "that")
    #expect(bound[1]["surfaceId"] as? String == "win-slack")

    let candidates = try #require(payload["candidateSurfaces"] as? [[String: Any]])
    #expect(candidates[0]["id"] as? String == "win-notes")
    #expect((candidates[0]["confidence"] as? NSNumber)?.doubleValue == 0.85)
    #expect(candidates[0]["source"] as? String == "fusion")
    #expect(candidates[1]["source"] as? String == "fusion")
}

// MARK: - Intent-aware system prompt (U2 — compose / decompose / no literal typing)

@Test func systemPromptTeachesComposeReadGenerateWriteWithoutLiteralTyping() {
    let prompt = NextToolCallPrompt.systemPrompt
    // Covers R1: compose tasks recognised, and the read → generate → write loop is spelled out.
    #expect(prompt.contains("COMPOSE TASKS"))
    #expect(prompt.contains("summarize"))
    #expect(prompt.contains("READ the source content"))
    #expect(prompt.contains("GENERATE the finished deliverable yourself"))
    // The deliverable surface for compose tasks is the write_note tool.
    #expect(prompt.contains("write_note"))
    // Never type the request verbatim; never hunt a verb-named button.
    #expect(prompt.contains("type_text"))
    #expect(prompt.contains("there is no \"Summarize\" control"))
    // Unreadable source → clarify, never fabricate.
    #expect(prompt.contains("clarify"))
    #expect(prompt.contains("never invent, guess, or fabricate a summary"))
}

@Test func systemPromptTeachesDecompositionAndNeverReissuingAFailedCall() {
    let prompt = NextToolCallPrompt.systemPrompt
    // Covers R2: multi-step decomposition + the no-loop guard.
    #expect(prompt.contains("DECOMPOSE a multi-step goal"))
    #expect(prompt.contains("NEVER re-issue a call"))
    #expect(prompt.contains("recentResults"))
}

@Test func systemPromptKeepsDeicticReferentGuidanceIntact() {
    let prompt = NextToolCallPrompt.systemPrompt
    // Regression guard (R5): fusion deixis guidance must survive the rewrite.
    #expect(prompt.contains("boundReferents"))
    #expect(prompt.contains("candidateSurfaces"))
    // U9: the prompt explains selectionText as the exact pointed text.
    #expect(prompt.contains("selectionText"))
}

@Test func carriesSelectionTextIntoPayloadAlongsideBoundReferents() throws {
    // Covers U9: the exact pointed text reaches the model payload next to boundReferents.
    let input = try makeInput(
        transcript: "summarize this", selectionText: "Bug: clicks no-op on Catalyst windows")
    let payload = try parseObject(NextToolCallPrompt.buildMessages(input, tools: try sampleTools())[1].content)
    #expect(payload["selectionText"] as? String == "Bug: clicks no-op on Catalyst windows")
    // Present (not absent) even when there is no selection — encoded as JSON null.
    let bare = try parseObject(NextToolCallPrompt.buildMessages(try makeInput(), tools: try sampleTools())[1].content)
    #expect(bare["selectionText"] is NSNull)
}

// MARK: - Contracts.ToolRisk (tool-risk.ts)

private let emptyElementTarget = Contracts.ToolCallTarget(
    element: .init(role: nil, title: nil, label: nil, value: nil), key: nil, keys: nil, pageAction: nil)

@Test func toolRiskClassifiesBasesAndRefinements() {
    #expect(Contracts.ToolRisk.riskForToolCall(.scroll) == .readOnly)
    #expect(Contracts.ToolRisk.riskForToolCall(.typeText) == .reversible)
    #expect(Contracts.ToolRisk.riskForToolCall(.killApp) == .destructiveExternal)

    // click: empty-but-present element → navigation base; commit element → mutating; no element → gated.
    #expect(Contracts.ToolRisk.riskForToolCall(.click, target: emptyElementTarget) == .reversible)
    let sendTarget = Contracts.ToolCallTarget(
        element: .init(role: nil, title: "Send", label: nil, value: nil), key: nil, keys: nil, pageAction: nil)
    #expect(Contracts.ToolRisk.riskForToolCall(.click, target: sendTarget) == .mutating)
    #expect(Contracts.ToolRisk.riskForToolCall(.click, target: nil) == .mutating)

    // press_key: nav key free, committing key gated.
    let downKey = Contracts.ToolCallTarget(element: nil, key: "down", keys: nil, pageAction: nil)
    let returnKey = Contracts.ToolCallTarget(element: nil, key: "return", keys: nil, pageAction: nil)
    #expect(Contracts.ToolRisk.riskForToolCall(.pressKey, target: downKey) == .readOnly)
    #expect(Contracts.ToolRisk.riskForToolCall(.pressKey, target: returnKey) == .mutating)

    // page sub-actions.
    let getText = Contracts.ToolCallTarget(element: nil, key: nil, keys: nil, pageAction: "get_text")
    let aeEnable = Contracts.ToolCallTarget(element: nil, key: nil, keys: nil, pageAction: "enable_javascript_apple_events")
    #expect(Contracts.ToolRisk.riskForToolCall(.page, target: getText) == .readOnly)
    #expect(Contracts.ToolRisk.riskForToolCall(.page, target: aeEnable) == .destructiveExternal)
}

@Test func toolRiskGatesUnknownNameAndMatchesCommitVerbsWordWise() {
    #expect(Contracts.ToolRisk.riskForToolName("format_disk") == .mutating)         // unknown → gated
    #expect(Contracts.ToolRisk.riskForToolName("scroll") == .readOnly)
    #expect(Contracts.ToolRisk.matchesCommitPattern("Send"))
    #expect(Contracts.ToolRisk.matchesCommitPattern("Post reply"))
    #expect(!Contracts.ToolRisk.matchesCommitPattern("Resend"))                     // word-ish, not substring
    #expect(!Contracts.ToolRisk.matchesCommitPattern("Description"))
}

// MARK: - IntentWorkerClient (provider boundary)

@Test func workerClientBuildsPostWithAppTokenAndResolvePath() throws {
    let client = try IntentWorkerClient(workerURL: "https://intent.example.workers.dev", appToken: "app-tok")
    let request = try client.makeRequest(model: "gpt-4o-mini", messages: [ChatMessage(role: "user", content: "{}")])

    #expect(request.url?.absoluteString == "https://intent.example.workers.dev/v1/resolve-intent")
    #expect(request.httpMethod == "POST")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer app-tok")
    #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")

    struct Body: Decodable { let model: String; let messages: [ChatMessage] }
    let body = try JSONDecoder().decode(Body.self, from: #require(request.httpBody))
    #expect(body.model == "gpt-4o-mini")
    #expect(body.messages == [ChatMessage(role: "user", content: "{}")])
}

@Test func workerClientRejectsNonHttpsAndEmptyToken() {
    #expect(throws: IntentWorkerError.self) {
        _ = try IntentWorkerClient(workerURL: "http://intent.example.workers.dev", appToken: "app-tok")
    }
    #expect(throws: IntentWorkerError.self) {
        _ = try IntentWorkerClient(workerURL: "https://intent.example.workers.dev", appToken: "  ")
    }
}

@Test func workerClientDecodesRealWorkerCompletionThroughResolver() async throws {
    // A real workers/llm-intent response shape: { choices:[{ finish_reason, message:{ parsed, refusal }}]}.
    let workerJSON = #"""
    {"choices":[{"finish_reason":"stop","message":{"parsed":{"status":"act","tool":"scroll","args":"{\"pid\":42,\"window_id\":7,\"direction\":\"down\"}","rationale":"Scroll the list","summary":null,"reason":null},"refusal":null}}]}
    """#
    let endpoint = URL(string: "https://intent.example.workers.dev/v1/resolve-intent")!
    let client = try IntentWorkerClient(workerURL: "https://intent.example.workers.dev", appToken: "app-tok") { _ in
        (Data(workerJSON.utf8), HTTPURLResponse(url: endpoint, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }

    let resolved = await NextToolCallResolver.resolveNextToolCall(try makeInput(), client: client, tools: try sampleTools())
    guard case let .ready(ready) = resolved, case let .toolCall(_, _, tool, args) = ready.actionPlan.actionPlan[0]
    else { Issue.record("expected ready tool_call"); return }
    #expect(tool == .scroll)
    #expect(args["direction"] == .string("down"))
}

@Test func workerClientSurfacesHttpErrorAsBlockedIntent() async throws {
    let endpoint = URL(string: "https://intent.example.workers.dev/v1/resolve-intent")!
    let client = try IntentWorkerClient(workerURL: "https://intent.example.workers.dev", appToken: "app-tok") { _ in
        (Data("{\"error\":\"openai_intent_request_failed\"}".utf8),
         HTTPURLResponse(url: endpoint, statusCode: 502, httpVersion: nil, headerFields: nil)!)
    }
    let resolved = await NextToolCallResolver.resolveNextToolCall(try makeInput(), client: client, tools: try sampleTools())
    guard case let .blocked(pending) = resolved else { Issue.record("expected blocked"); return }
    #expect(pending.reason.hasPrefix("Intent resolver failed:"))
    #expect(pending.reason.contains("HTTP 502"))
}

// MARK: - Helpers

private func parseObject(_ json: String) throws -> [String: Any] {
    try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
}
