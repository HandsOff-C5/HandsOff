//
//  LoopEngineTests.swift
//  DirectorSidecarTests
//
//  ADR 0005 Track D ("bridge or no-bridge" → no-bridge): tests for wiring the ported supervision
//  loop DIRECTLY into the app. Three layers:
//
//    • LoopFrameMapping — the pure projection of the loop's `Contracts.*` state onto the UI's
//      `BridgeFrame` family (the two intent / session / transcript families, and `satisfied`
//      having no lite case).
//    • IntentWorkerConfig — the env/plist resolver factory: real client when configured, a clean
//      `blocked` intent (no mock) when not.
//    • LoopEngine — command routing (greenlight→approve, reject→reject, stop/pause→interrupt),
//      the speech `.final`→goal trigger, and the @Observable→frame projection (driver/resolver are
//      faked; a real camera/mic/driver can't run under headless xcodebuild).
//

import Testing
import Foundation
@testable import DirectorSidecar

// MARK: - Fakes (file-private; mirror VoiceCuaLoopTests' scripted fakes)

private actor FakeLoopDriver: CuaLoopDriver {
    private let windows: [CuaWindow]
    private let windowState: CuaWindowState?
    private let callResults: [String: CuaResult<JSONValue>]
    private(set) var genericCalls: [String] = []

    init(windows: [CuaWindow], windowState: CuaWindowState?,
         callResults: [String: CuaResult<JSONValue>] = [:]) {
        self.windows = windows
        self.windowState = windowState
        self.callResults = callResults
    }

    func listWindows() -> CuaResult<[CuaWindow]> { .succeeded(windows) }
    func getWindowState(pid: Int, windowId: Int) -> CuaResult<CuaWindowState> {
        windowState.map { .succeeded($0) } ?? .failed(error: "no window state")
    }
    func screenshot(pid: Int, windowId: Int) -> CuaResult<CuaScreenshot> { .failed(error: "no screenshot") }
    func listTools() -> CuaResult<[DriverToolDefinition]> { .succeeded([]) }
    func call(tool: String, input: JSONValue) -> CuaResult<JSONValue> {
        genericCalls.append(tool)
        return callResults[tool] ?? .succeeded(.object([:]))
    }
    func recordedCalls() -> [String] { genericCalls }
}

private actor ScriptedResolver {
    private let decisions: [NextToolCall]
    private var index = 0
    init(_ decisions: [NextToolCall]) { self.decisions = decisions }

    func resolve(_ input: Contracts.IntentInput, _ createdAt: String) -> Contracts.ResolvedIntent {
        let decision = index < decisions.count
            ? decisions[index]
            : NextToolCall(status: .blocked, tool: nil, args: nil, rationale: "exhausted",
                           summary: nil, reason: "script exhausted")
        index += 1
        return NextToolCallResolver.nextToolCallToIntent(
            decision, input: input, id: "intent-\(index)", createdAt: createdAt)
    }
}

// MARK: - Builders

private func finalTranscript(_ text: String) -> Contracts.FinalTranscript {
    Contracts.FinalTranscript(text: text, confidence: 0.95, latencyMs: 100, receivedAt: 1)
}

private func makeInput(_ text: String) -> Contracts.IntentInput {
    Contracts.IntentInput(sessionId: "s1", finalTranscript: finalTranscript(text),
                          pointingEvidence: [], surfaceCandidates: [], goalSession: nil)
}

private func focusedWindow(pid: Int = 42, windowId: Int = 7) -> CuaWindow {
    CuaWindow(id: "win-1", title: "Codex", app: "Codex", pid: pid, windowId: windowId,
              availability: .available, accessStatus: .accessible, focused: true,
              bounds: nil, zIndex: 0)
}

private func windowState(commitLabel: String = "Send") -> CuaWindowState {
    CuaWindowState(surface: focusedWindow(), capturedAt: "2026-06-22T12:00:00.000Z",
                   elementCount: 1,
                   elements: [CuaElement(id: "e0", index: 0, role: "AXButton", label: commitLabel, value: nil)])
}

private func act(_ tool: String, args: String? = nil) -> NextToolCall {
    NextToolCall(status: .act, tool: tool, args: args, rationale: "do \(tool)", summary: nil, reason: nil)
}
private func done(_ summary: String = "Goal satisfied") -> NextToolCall {
    NextToolCall(status: .done, tool: nil, args: nil, rationale: "done", summary: summary, reason: nil)
}
private let clickSendArgs = #"{"element_index":0}"#

@MainActor
private func makeLoop(driver: FakeLoopDriver, resolver: ScriptedResolver) -> VoiceCuaLoop {
    // `defaultToolCallBudget` is referenced in this @MainActor body (not a default-arg expression),
    // so it stays main-actor-isolated — the nonisolated-default-arg quirk DirectorServices documents.
    VoiceCuaLoop(
        driver: driver,
        resolve: { input, createdAt, _ in await resolver.resolve(input, createdAt) },
        now: { "2026-06-22T12:00:00.000Z" },
        targetResolveDelayMs: 0,
        toolCallBudget: VoiceCuaLoop.defaultToolCallBudget)
}

private func fakeReadiness(mic: String = "granted", speech: String = "granted") -> ReadinessPayload {
    ReadinessPayload(capabilities: [
        CapabilityProbe(id: "microphone", kind: "permission", state: mic),
        CapabilityProbe(id: "speech-recognition", kind: "permission", state: speech),
    ])
}

// MARK: - Frame capture + async drain

@MainActor private final class Captured {
    var frames: [BridgeFrame] = []
    var states: [ConnectionState] = []
}

@MainActor
private func makeEngine(loop: VoiceCuaLoop, readiness: @escaping @Sendable () -> ReadinessPayload = { fakeReadiness() }) -> (LoopEngine, Captured) {
    let captured = Captured()
    let engine = LoopEngine(loop: loop, readinessProbe: readiness)
    engine.onFrame = { captured.frames.append($0) }
    engine.onState = { captured.states.append($0) }
    return (engine, captured)
}

/// Poll the main actor until `condition` holds (Observation emits frames on a later main-actor turn).
///
/// Budget is generous (5s) because these tests drive the loop through the fire-and-forget `goalTask`
/// and wait on its Observation-driven frames — all of which serialize onto the single main actor. On
/// the coverage-instrumented, heavily-parallel CI runner the goal needs many more wall-clock ms to win
/// enough main-actor turns than it does on a fast dev machine; a tight budget makes the wait flaky
/// (CI timed out at ~2–3s) without indicating any real failure. A genuinely stuck goal still fails —
/// it just takes up to `timeoutMs` to do so.
@MainActor
private func waitUntil(timeoutMs: Int = 5000, _ condition: () -> Bool) async {
    let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000)
    while !condition() && Date() < deadline {
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(2))
    }
}

private func intentFrames(_ frames: [BridgeFrame]) -> [ResolvedIntentLite] {
    frames.compactMap { if case let .intent(intent) = $0 { return intent } else { return nil } }
}
private func transcriptFrames(_ frames: [BridgeFrame]) -> [TranscriptEvent] {
    frames.compactMap { if case let .transcript(event) = $0 { return event } else { return nil } }
}
private func sessionsFrames(_ frames: [BridgeFrame]) -> [SessionsPayload] {
    frames.compactMap { if case let .sessions(payload) = $0 { return payload } else { return nil } }
}
private func runResultFrames(_ frames: [BridgeFrame]) -> [RunResultPayload] {
    frames.compactMap { if case let .runResult(payload) = $0 { return payload } else { return nil } }
}
private func readinessFrames(_ frames: [BridgeFrame]) -> [ReadinessPayload] {
    frames.compactMap { if case let .state(topic, readiness) = $0, topic == "readiness" { return readiness } else { return nil } }
}
private func auditFrames(_ frames: [BridgeFrame]) -> [AuditLogPayload] {
    frames.compactMap { if case let .audit(payload) = $0 { return payload } else { return nil } }
}

// MARK: - Mapping tests

struct LoopFrameMappingTests {
    @Test func readyIntentMapsToLiteWithToolCallSteps() {
        let ready = NextToolCallResolver.nextToolCallToIntent(
            act("scroll"), input: makeInput("scroll"), id: "i1", createdAt: "t")
        let lite = LoopFrameMapping.lite(from: ready)
        #expect(lite?.status == .ready)
        #expect(lite?.requiresApproval == false)
        #expect(lite?.intentType == "inspect")
        #expect(lite?.summary == "do scroll")
        #expect(lite?.steps.count == 1)
        #expect(lite?.steps.first?.kind == "tool_call")
        #expect(lite?.id == "i1")
    }

    @Test func satisfiedIntentHasNoLiteRepresentation() {
        let satisfied = NextToolCallResolver.nextToolCallToIntent(
            done("all done"), input: makeInput("done"), id: "i1", createdAt: "t")
        #expect(LoopFrameMapping.lite(from: satisfied) == nil)
        #expect(LoopFrameMapping.lite(from: nil) == nil)
    }

    @Test func blockedIntentMapsToLiteWithReason() {
        let blocked = NextToolCallResolver.nextToolCallToIntent(
            NextToolCall(status: .blocked, tool: nil, args: nil, rationale: "x", summary: nil, reason: "cannot"),
            input: makeInput("nope"), id: "i1", createdAt: "t")
        let lite = LoopFrameMapping.lite(from: blocked)
        #expect(lite?.status == .blocked)
        #expect(lite?.reason == "cannot")
        #expect(lite?.steps.isEmpty == true)
    }

    @Test func clarificationMapsToLite() {
        let clarify = NextToolCallResolver.nextToolCallToIntent(
            NextToolCall(status: .clarify, tool: nil, args: nil, rationale: "x", summary: nil, reason: "which one?"),
            input: makeInput("do it"), id: "i1", createdAt: "t")
        let lite = LoopFrameMapping.lite(from: clarify)
        #expect(lite?.status == .clarificationRequired)
        #expect(lite?.reason == "which one?")
    }

    @Test func wireSessionCarriesEnrichment() {
        let core = Contracts.SupervisionSession(
            id: "session-1", status: .running, startedAt: "a", updatedAt: "b", finishedAt: nil)
        let wire = LoopFrameMapping.wireSession(core, title: "open mail", agentLabel: "Director")
        #expect(wire.id == "session-1")
        #expect(wire.status == .running)
        #expect(wire.title == "open mail")
        #expect(wire.agentLabel == "Director")
        #expect(wire.finishedAt == nil)
    }

    @Test func transcriptMapsPartialAndFinal() {
        let partial = LoopFrameMapping.transcript(partial: true, text: "he", confidence: 0, latencyMs: 1, receivedAt: 2)
        let final = LoopFrameMapping.transcript(partial: false, text: "hello", confidence: 0.9, latencyMs: 3, receivedAt: 4)
        #expect(partial.kind == "partial")
        #expect(partial.text == "he")
        #expect(final.kind == "final")
        #expect(final.confidence == 0.9)
    }

    // MARK: audit projection (H4)

    @Test func auditLogProjectsToolCallProvenance() {
        let event = Contracts.SupervisionAuditEvent.toolCall(
            .init(sessionId: "session-1", actionId: "act-1", recordedAt: "t0"),
            .init(transcript: "send it", referent: nil, tool: .click, target: nil,
                  risk: .mutating, approval: .approved,
                  result: .succeeded(summary: "Clicked Send", state: nil)))
        let payload = LoopFrameMapping.auditLog([event])
        #expect(payload.entries.count == 1)
        let entry = payload.entries[0]
        #expect(entry.kind == .toolCall)
        #expect(entry.sessionId == "session-1")
        #expect(entry.actionId == "act-1")
        #expect(entry.tool == "click")
        #expect(entry.risk == .mutating)           // derived risk surfaced as a first-class field
        #expect(entry.approval == .approved)       // approval state surfaced
        #expect(entry.result == .succeeded)        // result surfaced
        #expect(entry.summary == "Tool click [approved]: Clicked Send")
        #expect(entry.id == "session-1#0")
    }

    @Test func auditLogSummarizesNonToolCallKinds() {
        let ready = NextToolCallResolver.nextToolCallToIntent(
            act("scroll"), input: makeInput("scroll"), id: "i1", createdAt: "t")
        let intentEvent = Contracts.SupervisionAuditEvent.intentCreated(
            .init(sessionId: "s", actionId: "a", recordedAt: "t0"), intent: ready)
        let finishEvent = Contracts.SupervisionAuditEvent.executionFinished(
            .init(sessionId: "s", actionId: "a", recordedAt: "t1"), status: .succeeded,
            result: .succeeded(summary: "done", state: nil))
        let entries = LoopFrameMapping.auditLog([intentEvent, finishEvent]).entries
        #expect(entries[0].kind == .intentCreated)
        #expect(entries[0].summary == "Plan ready: do scroll") // ready → action_plan.summary
        #expect(entries[0].risk == nil)                        // non-tool_call rows carry no chips
        #expect(entries[0].id == "s#0")
        #expect(entries[1].kind == .executionFinished)
        #expect(entries[1].summary == "Finished: succeeded: done")
        #expect(entries[1].id == "s#1")                        // ordinal disambiguates same recordedAt
    }

    @Test func auditResultSummaryPrefersFailureMessage() {
        let blocked = Contracts.SupervisionAuditEvent.toolCall(
            .init(sessionId: "s", actionId: "a", recordedAt: "t"),
            .init(transcript: "x", referent: nil, tool: .killApp, target: nil,
                  risk: .destructiveExternal, approval: .rejected,
                  result: .blocked(reason: "needs approval", state: nil)))
        let entry = LoopFrameMapping.auditLog([blocked]).entries[0]
        #expect(entry.result == .blocked)
        #expect(entry.summary == "Tool kill_app [rejected]: needs approval")
    }
}

// MARK: - IntentWorkerConfig tests

struct IntentWorkerConfigTests {
    @Test func valueTrimsAndTreatsBlankAsAbsent() {
        #expect(IntentWorkerConfig.value("K", env: ["K": "  v  "], bundle: .main) == "v")
        #expect(IntentWorkerConfig.value("K", env: ["K": "   "], bundle: .main) == nil)
        #expect(IntentWorkerConfig.value("K", env: [:], bundle: .main) == nil)
    }

    @Test func clientBuiltOnlyWhenBothHalvesPresentAndValid() {
        let ok = IntentWorkerConfig.client(env: [
            IntentWorkerConfig.workerURLKey: "https://intent.example.workers.dev",
            IntentWorkerConfig.appTokenKey: "tok-123",
        ], bundle: .main)
        #expect(ok != nil)

        // Missing token.
        #expect(IntentWorkerConfig.client(env: [
            IntentWorkerConfig.workerURLKey: "https://intent.example.workers.dev",
        ], bundle: .main) == nil)

        // Non-https URL is rejected by the client.
        #expect(IntentWorkerConfig.client(env: [
            IntentWorkerConfig.workerURLKey: "http://intent.example.workers.dev",
            IntentWorkerConfig.appTokenKey: "tok-123",
        ], bundle: .main) == nil)
    }

    @Test func resolverDegradesToBlockedWhenUnconfigured() async {
        let resolver = IntentWorkerConfig.resolver(env: [:], bundle: .main)
        let intent = await resolver(makeInput("hi"), "t", [])
        guard case let .blocked(pending) = intent else {
            Issue.record("expected a blocked intent when the worker is unconfigured")
            return
        }
        #expect(pending.reason.contains("not configured"))
        #expect(pending.reason.contains(IntentWorkerConfig.workerURLKey))
    }
}

// MARK: - LoopEngine command routing

@MainActor
struct LoopEngineCommandTests {
    @Test func greenlightRoutesToApproveAndDispatches() async {
        let driver = FakeLoopDriver(windows: [focusedWindow()], windowState: windowState(commitLabel: "Send"))
        let resolver = ScriptedResolver([act("click", args: clickSendArgs), done()])
        let loop = makeLoop(driver: driver, resolver: resolver)
        let (engine, _) = makeEngine(loop: loop)

        await loop.handleFinalTranscript(finalTranscript("send it")) // pauses at approval
        #expect(await driver.recordedCalls().isEmpty)

        await engine.send(.greenlight(actionId: "x", decidedAt: "t"))
        #expect(await driver.recordedCalls() == ["click"])
        #expect(loop.session?.status == .succeeded)
    }

    @Test func rejectRoutesToRejectAndRunsNothing() async {
        let driver = FakeLoopDriver(windows: [focusedWindow()], windowState: windowState(commitLabel: "Send"))
        let resolver = ScriptedResolver([act("click", args: clickSendArgs)])
        let loop = makeLoop(driver: driver, resolver: resolver)
        let (engine, _) = makeEngine(loop: loop)

        await loop.handleFinalTranscript(finalTranscript("send it"))
        await engine.send(.reject(actionId: "x", decidedAt: "t"))

        #expect(loop.session?.status == .rejected)
        #expect(await driver.recordedCalls().isEmpty)
    }

    @Test func stopListeningRoutesToInterrupt() async {
        let driver = FakeLoopDriver(windows: [focusedWindow()], windowState: windowState(commitLabel: "Send"))
        let resolver = ScriptedResolver([act("click", args: clickSendArgs)])
        let loop = makeLoop(driver: driver, resolver: resolver)
        let (engine, _) = makeEngine(loop: loop)

        await loop.handleFinalTranscript(finalTranscript("send it")) // paused at approval
        await engine.send(.stopListening)

        #expect(loop.session?.status == .blocked)
        #expect(await driver.recordedCalls().isEmpty)
    }

    @Test func pauseAllRoutesToInterrupt() async {
        let driver = FakeLoopDriver(windows: [focusedWindow()], windowState: windowState(commitLabel: "Send"))
        let resolver = ScriptedResolver([act("click", args: clickSendArgs)])
        let loop = makeLoop(driver: driver, resolver: resolver)
        let (engine, _) = makeEngine(loop: loop)

        await loop.handleFinalTranscript(finalTranscript("send it"))
        await engine.send(.pauseAll)

        #expect(loop.session?.status == .blocked)
    }

    @Test func pauseSessionRoutesToInterrupt() async {
        let driver = FakeLoopDriver(windows: [focusedWindow()], windowState: windowState(commitLabel: "Send"))
        let resolver = ScriptedResolver([act("click", args: clickSendArgs)])
        let loop = makeLoop(driver: driver, resolver: resolver)
        let (engine, _) = makeEngine(loop: loop)

        await loop.handleFinalTranscript(finalTranscript("send it"))
        await engine.send(.pauseSession("session-1"))

        #expect(loop.session?.status == .blocked)
    }

    @Test func uiOnlyCommandsDoNotDisturbTheLoop() async {
        let driver = FakeLoopDriver(windows: [focusedWindow()], windowState: windowState())
        let resolver = ScriptedResolver([act("scroll"), done()])
        let loop = makeLoop(driver: driver, resolver: resolver)
        let (engine, _) = makeEngine(loop: loop)

        // commit / openHome / selectSession / startListening are no-ops at the loop layer.
        await engine.send(.commit)
        await engine.send(.openHome)
        await engine.send(.selectSession("session-1"))
        await engine.send(.startListening)
        #expect(loop.session == nil)
        #expect(await driver.recordedCalls().isEmpty)
    }
}

// MARK: - LoopEngine speech + frame projection

@MainActor
struct LoopEngineProjectionTests {
    @Test func startEmitsConnectedAndReadiness() {
        let driver = FakeLoopDriver(windows: [focusedWindow()], windowState: windowState())
        let resolver = ScriptedResolver([done()])
        let loop = makeLoop(driver: driver, resolver: resolver)
        let (engine, captured) = makeEngine(loop: loop, readiness: { fakeReadiness(mic: "granted", speech: "granted") })

        engine.start()

        #expect(captured.states == [.connected])
        let readiness = readinessFrames(captured.frames)
        #expect(readiness.count == 1)
        #expect(readiness.first?.capabilities.contains { $0.id == "microphone" && $0.state == "granted" } == true)
    }

    @Test func partialSpeechEmitsTranscriptWithoutStartingGoal() {
        let driver = FakeLoopDriver(windows: [focusedWindow()], windowState: windowState())
        let resolver = ScriptedResolver([done()])
        let loop = makeLoop(driver: driver, resolver: resolver)
        let (engine, captured) = makeEngine(loop: loop)
        engine.start()

        engine.ingestSpeech(.partial(text: "scrol", confidence: 0, latencyMs: 1, receivedAt: 1))

        #expect(transcriptFrames(captured.frames).last?.kind == "partial")
        #expect(loop.session == nil) // no goal started by a partial
    }

    @Test func finalSpeechEmitsTranscriptAndStartsGoal() async {
        let driver = FakeLoopDriver(windows: [focusedWindow()], windowState: windowState())
        let resolver = ScriptedResolver([act("scroll"), done()])
        let loop = makeLoop(driver: driver, resolver: resolver)
        let (engine, captured) = makeEngine(loop: loop)
        engine.start()

        engine.ingestSpeech(.final(text: "scroll the page", confidence: 0.9, latencyMs: 1, receivedAt: 1))

        #expect(transcriptFrames(captured.frames).last?.kind == "final")
        await waitUntil { loop.session?.status == .succeeded }
        #expect(loop.session?.status == .succeeded)
        #expect(await driver.recordedCalls() == ["scroll"])
    }

    @Test func errorSpeechEmitsErrorFrame() {
        let driver = FakeLoopDriver(windows: [focusedWindow()], windowState: windowState())
        let resolver = ScriptedResolver([done()])
        let loop = makeLoop(driver: driver, resolver: resolver)
        let (engine, captured) = makeEngine(loop: loop)
        engine.start()

        engine.ingestSpeech(.error(SpeechService.SttError(kind: .micPermission, message: "mic off"), receivedAt: 1))

        let hasError = captured.frames.contains { if case let .error(reason) = $0 { return reason == "mic off" } else { return false } }
        #expect(hasError)
    }

    @Test func goalProjectsReadyIntentAndSessionFrames() async {
        let driver = FakeLoopDriver(windows: [focusedWindow()], windowState: windowState(commitLabel: "Send"))
        let resolver = ScriptedResolver([act("click", args: clickSendArgs), done()])
        let loop = makeLoop(driver: driver, resolver: resolver)
        let (engine, captured) = makeEngine(loop: loop)
        engine.start()

        // The real entry path: a final transcript starts the goal (and titles the session).
        engine.ingestSpeech(.final(text: "send it", confidence: 0.9, latencyMs: 1, receivedAt: 1))

        // The goal runs async + pauses at the mutating-approval boundary; Observation emits frames on
        // a later main-actor turn — wait for the ready-approval intent frame.
        await waitUntil { intentFrames(captured.frames).contains { $0.status == .ready && $0.requiresApproval } }
        #expect(intentFrames(captured.frames).contains { $0.status == .ready && $0.requiresApproval })
        // At the pause the session is still queued (it goes .running only when the action dispatches),
        // and it is titled by the spoken transcript.
        #expect(sessionsFrames(captured.frames).last?.sessions.first?.status == .queued)
        #expect(sessionsFrames(captured.frames).last?.sessions.first?.title == "send it")

        await engine.send(.greenlight(actionId: "x", decidedAt: "t"))
        await waitUntil { runResultFrames(captured.frames).contains { $0.status == .succeeded } }
        #expect(runResultFrames(captured.frames).contains { $0.status == .succeeded })
        #expect(loop.session?.status == .succeeded)
    }

    @Test func goalProjectsAuditFrameWithToolCallProvenance() async {
        // H4: the regression. A run's per-call Intention Log must reach the UI as an `audit` frame —
        // before this fix `emitCurrentState` never read `loop.auditEvents`, so the log was invisible.
        let driver = FakeLoopDriver(windows: [focusedWindow()], windowState: windowState())
        let resolver = ScriptedResolver([act("scroll"), done()]) // read-only → auto-runs to success
        let loop = makeLoop(driver: driver, resolver: resolver)
        let (engine, captured) = makeEngine(loop: loop)
        engine.start()

        engine.ingestSpeech(.final(text: "scroll the page", confidence: 0.9, latencyMs: 1, receivedAt: 1))
        await waitUntil { loop.session?.status == .succeeded }
        await waitUntil { auditFrames(captured.frames).contains { p in p.entries.contains { $0.kind == .toolCall } } }

        let toolCalls = auditFrames(captured.frames).flatMap(\.entries).filter { $0.kind == .toolCall }
        #expect(!toolCalls.isEmpty)
        #expect(toolCalls.contains { $0.tool == "scroll" })
        #expect(toolCalls.allSatisfy { $0.risk != nil })       // every tool_call row carries derived risk
        #expect(toolCalls.allSatisfy { $0.approval == .auto })  // read-only auto-ran, no human gate
        #expect(toolCalls.contains { $0.result == .succeeded })
    }
}
