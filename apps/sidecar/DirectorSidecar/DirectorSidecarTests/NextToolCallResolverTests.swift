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

/// A small `CuaScreenshot` fixture for the U5 vision path — a 1×1 PNG payload is enough to assert the
/// inline `data:` image part is assembled; `pngBase64` is overridable for the over-cap degrade case.
private func makeScreenshot(
    pngBase64: String = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR4nGNgYGAAAAAEAAH2FzhVAAAAAElFTkSuQmCC",
    mimeType: String = "image/png"
) -> CuaScreenshot {
    let window = CuaWindow(
        id: "notes:1", title: "Quick Note", app: "Notes", pid: 42, windowId: 7,
        availability: .available, accessStatus: .accessible, focused: true, bounds: nil, zIndex: 0)
    return CuaScreenshot(
        surface: window, capturedAt: "2026-06-22T12:00:02.000Z",
        mimeType: mimeType, width: 1, height: 1, pngBase64: pngBase64)
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
    let payload = try parseObject(textPayload(messages[1].content))

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
    let payload = try parseObject(textPayload(NextToolCallPrompt.buildMessages(input, tools: try sampleTools())[1].content))

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
    let payload = try parseObject(textPayload(NextToolCallPrompt.buildMessages(input, tools: try sampleTools())[1].content))
    #expect(payload["selectionText"] as? String == "Bug: clicks no-op on Catalyst windows")
    // Present (not absent) even when there is no selection — encoded as JSON null.
    let bare = try parseObject(textPayload(NextToolCallPrompt.buildMessages(try makeInput(), tools: try sampleTools())[1].content))
    #expect(bare["selectionText"] is NSNull)
}

// MARK: - U5 screenshot threading + U11 app-context injection (Phase 2, additive)

@Test func threadsScreenshotAsInlineImagePartAlongsideTextPayload() throws {
    // U5: a present screenshot makes the user turn multimodal — the JSON payload as the leading text
    // part, the capture as an inline `data:image/png;base64,…` image part.
    let messages = NextToolCallPrompt.buildMessages(
        try makeInput(), tools: try sampleTools(),
        screenshot: makeScreenshot(pngBase64: "iVBORw0KGgoAAAA="))
    #expect(messages.count == 2)
    guard case let .parts(parts) = messages[1].content else {
        Issue.record("expected multimodal user content, got \(messages[1].content)"); return
    }
    // The encoded JSON payload survives as the leading text part…
    guard case let .text(text) = parts[0] else { Issue.record("expected leading text part"); return }
    #expect(try parseObject(text)["goal"] != nil)
    // …and the screenshot rides as an inline data: image part.
    let imagePart = parts.first { if case .imageURL = $0 { return true } else { return false } }
    guard case let .imageURL(url) = try #require(imagePart) else { Issue.record("expected image part"); return }
    #expect(url == "data:image/png;base64,iVBORw0KGgoAAAA=")
}

@Test func textOnlyPathIsByteIdenticalWithNilScreenshotAndUnknownApp() throws {
    // Regression: nil screenshot + an unknown app (no observations, head-only evidence, a non-catalog
    // candidate) must produce the exact pre-Phase-2 two-turn output — bare system prompt, string user.
    let input = try makeInput(
        pointingEvidence: [["source": "head", "confidence": 0.9, "strategy": "head-neighborhood"]],
        surfaceCandidates: [surfaceDict(app: "Xcode")])
    let messages = NextToolCallPrompt.buildMessages(input, tools: try sampleTools())
    #expect(messages.count == 2)
    // System turn is the bare prompt — no app section appended (ChatMessage is Equatable).
    #expect(messages[0] == ChatMessage(role: "system", content: NextToolCallPrompt.systemPrompt))
    // User turn is the legacy string-content form (NOT multimodal), role unchanged.
    #expect(messages[1].role == "user")
    guard case .text = messages[1].content else { Issue.record("expected string-content user turn"); return }
}

@Test func overCapScreenshotDegradesToTextOnlyUserTurn() throws {
    // U5 guard: an inline image past `ContentPart.maxImageBase64Bytes` must NOT fail the resolve —
    // buildMessages drops the image and keeps the text turn so the loop keeps making progress AX-only.
    let huge = String(repeating: "A", count: ContentPart.maxImageBase64Bytes + 1)
    let messages = NextToolCallPrompt.buildMessages(
        try makeInput(), tools: try sampleTools(), screenshot: makeScreenshot(pngBase64: huge))
    #expect(messages.count == 2)
    guard case let .text(text) = messages[1].content else {
        Issue.record("expected text-only user turn after over-cap image drop"); return
    }
    #expect(try parseObject(text)["goal"] != nil)
}

@Test func injectsKnownFocusedAppContextIntoSystemTurn() throws {
    // U11: the latest observation's focused window app drives the lookup — a catalog hit appends the
    // app fragment to the system turn (after the intact U2 prompt); an unknown app leaves it bare.
    let chrome = surfaceDict(id: "chrome:1", title: "GitHub", app: "Google Chrome", pid: 99, windowId: 3)
    let known = try makeInput(goalSession: [
        "goal": "open the repo", "tick": 1,
        "observations": [[
            "tick": 1, "capturedAt": "2026-06-22T12:00:01.000Z", "windows": [chrome],
            "state": ["surface": chrome, "capturedAt": "2026-06-22T12:00:01.000Z", "elementCount": 0, "elements": []],
        ]],
    ])
    let system = NextToolCallPrompt.buildMessages(known, tools: try sampleTools())[0]
    #expect(system.role == "system")
    guard case let .text(text) = system.content else { Issue.record("expected text system turn"); return }
    #expect(text.hasPrefix(NextToolCallPrompt.systemPrompt))                       // U2 guidance survives…
    #expect(text.contains("App context — Chromium browser (Chrome / Brave):"))    // …with the U11 fragment…
    #expect(text.contains("Cmd+L = focus the address/search bar"))
    #expect(text.contains(AppContextCatalog.guardrail))                           // …closing with the guardrail.

    // An unknown focused app leaves the system turn exactly the bare prompt.
    let slack = surfaceDict(id: "slack:1", title: "Slack", app: "Slack", pid: 5, windowId: 9)
    let unknown = try makeInput(goalSession: [
        "goal": "read the channel", "tick": 1,
        "observations": [[
            "tick": 1, "capturedAt": "2026-06-22T12:00:01.000Z", "windows": [slack],
            "state": ["surface": slack, "capturedAt": "2026-06-22T12:00:01.000Z", "elementCount": 0, "elements": []],
        ]],
    ])
    #expect(NextToolCallPrompt.buildMessages(unknown, tools: try sampleTools())[0]
        == ChatMessage(role: "system", content: NextToolCallPrompt.systemPrompt))
}

@Test func fusionPayloadKeysSurviveScreenshotAndAppContextInjection() throws {
    // Regression (the differentiator): with BOTH a screenshot and a known app, the user payload still
    // carries the live fusion keys (boundReferents / selectionText / candidateSurfaces) intact, and
    // the app context only ever lands in the SYSTEM turn.
    let notes = surfaceDict(id: "win-notes", title: "Notes", app: "Notes")
    let input = try makeInput(
        transcript: "summarize this",
        pointingEvidence: [["source": "fusion", "confidence": 0.9, "strategy": "temporal-bind:this@1100", "surface": notes]],
        surfaceCandidates: [notes],
        selectionText: "the selected passage")
    let messages = NextToolCallPrompt.buildMessages(input, tools: try sampleTools(), screenshot: makeScreenshot())
    guard case let .parts(parts) = messages[1].content, case let .text(text) = parts[0] else {
        Issue.record("expected multimodal user turn with leading text"); return
    }
    let payload = try parseObject(text)
    let bound = try #require(payload["boundReferents"] as? [[String: Any]])
    #expect(bound.first?["word"] as? String == "this")
    #expect(payload["selectionText"] as? String == "the selected passage")
    let candidates = try #require(payload["candidateSurfaces"] as? [[String: Any]])
    #expect(candidates.first?["id"] as? String == "win-notes")
    // The app context lands in the SYSTEM turn (Notes is in the catalog), never the user payload.
    guard case let .text(system) = messages[0].content else { Issue.record("expected text system turn"); return }
    #expect(system.contains("App context — Notes:"))
    #expect(payload["appContext"] == nil)
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

/// The JSON text payload of a user turn — the bare string for a legacy string-content message, or the
/// leading text part of a multimodal (text + image) message. The resolver's user turn is one or the
/// other, so this lets a test read the payload uniformly across the text-only and vision paths.
private func textPayload(_ content: ChatMessage.Content) throws -> String {
    switch content {
    case let .text(text):
        return text
    case let .parts(parts):
        for case let .text(text) in parts { return text }
        throw DescribedError(description: "no text part in multimodal content")
    }
}
