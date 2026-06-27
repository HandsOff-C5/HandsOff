//
//  VoiceCuaLoopTests.swift
//  DirectorSidecarTests
//
//  Track A loop-core tests: the observe → resolve → risk-gate → dispatch → observe supervision
//  loop (`VoiceCuaLoop`), the Swift port of useVoiceCuaController.ts. Mirrors that file's behavioral
//  invariants — the U3 characterization set, the autonomous-loop recovery/gate/audit/interrupt
//  cases, the U3b full-surface `driver.call` dispatch, the BUG-4 dedup floor, the action budget,
//  and the done→succeeded terminal — driven through fakes (a real camera/mic/driver can't run under
//  headless xcodebuild).
//
//  The fake resolver scripts a sequence of `NextToolCall` decisions and maps each through the REAL
//  `NextToolCallResolver.nextToolCallToIntent` (Track C), so the act→ready-tool_call path, the risk
//  derivation, and the done/clarify/blocked mapping are exercised, not stubbed. The fake driver
//  scripts window/state/call results and records the generic `call` dispatches the loop makes.
//

import Testing
import Foundation
@testable import DirectorSidecar

// MARK: - Fakes

/// A scripted CUA driver. `listWindows`/`getWindowState` return a fixed focused window + state;
/// generic `call` returns a per-tool scripted result (default success) and records the dispatch.
private actor FakeLoopDriver: CuaLoopDriver {
    private let windows: [CuaWindow]
    private let windowState: CuaWindowState?
    private let tools: [DriverToolDefinition]
    private let callResults: [String: CuaResult<JSONValue>]
    private(set) var genericCalls: [String] = []

    init(
        windows: [CuaWindow],
        windowState: CuaWindowState?,
        tools: [DriverToolDefinition] = [],
        callResults: [String: CuaResult<JSONValue>] = [:]
    ) {
        self.windows = windows
        self.windowState = windowState
        self.tools = tools
        self.callResults = callResults
    }

    func listWindows() -> CuaResult<[CuaWindow]> { .succeeded(windows) }

    func getWindowState(pid: Int, windowId: Int) -> CuaResult<CuaWindowState> {
        windowState.map { .succeeded($0) } ?? .failed(error: "no window state")
    }

    func listTools() -> CuaResult<[DriverToolDefinition]> { .succeeded(tools) }

    func call(tool: String, input: JSONValue) -> CuaResult<JSONValue> {
        genericCalls.append(tool)
        return callResults[tool] ?? .succeeded(.object([:]))
    }

    func recordedCalls() -> [String] { genericCalls }
}

/// A scripted resolver: hand back the next `NextToolCall` decision (mapped through the real
/// resolver), recording every input it saw so a test can prove observe-before-act.
private actor ScriptedResolver {
    private let decisions: [NextToolCall]
    private var index = 0
    private(set) var inputs: [Contracts.IntentInput] = []

    init(_ decisions: [NextToolCall]) { self.decisions = decisions }

    func resolve(_ input: Contracts.IntentInput, _ createdAt: String) -> Contracts.ResolvedIntent {
        inputs.append(input)
        let decision = index < decisions.count
            ? decisions[index]
            : NextToolCall(status: .blocked, tool: nil, args: nil, rationale: "exhausted",
                           summary: nil, reason: "script exhausted")
        index += 1
        return NextToolCallResolver.nextToolCallToIntent(
            decision, input: input, id: "intent-\(index)", createdAt: createdAt)
    }

    func seenInputs() -> [Contracts.IntentInput] { inputs }
}

// MARK: - Builders

private func finalTranscript(_ text: String) -> Contracts.FinalTranscript {
    let json = #"{"kind":"final","text":"\#(text)","confidence":0.95,"latencyMs":100,"receivedAt":1}"#
    // swiftlint:disable:next force_try
    return try! JSONDecoder().decode(Contracts.FinalTranscript.self, from: Data(json.utf8))
}

private func focusedWindow(pid: Int = 42, windowId: Int = 7) -> CuaWindow {
    CuaWindow(id: "win-1", title: "Codex", app: "Codex", pid: pid, windowId: windowId,
              availability: .available, accessStatus: .accessible, focused: true,
              bounds: nil, zIndex: 0)
}

private func windowState(commitLabel: String = "Send Message") -> CuaWindowState {
    CuaWindowState(
        surface: focusedWindow(),
        capturedAt: "2026-06-22T12:00:00.000Z",
        elementCount: 1,
        elements: [CuaElement(id: "e0", index: 0, role: "AXButton", label: commitLabel, value: nil)])
}

private func act(_ tool: String, args: String? = nil) -> NextToolCall {
    NextToolCall(status: .act, tool: tool, args: args, rationale: "do \(tool)", summary: nil, reason: nil)
}

private func done(_ summary: String = "Goal satisfied") -> NextToolCall {
    NextToolCall(status: .done, tool: nil, args: nil, rationale: "done", summary: summary, reason: nil)
}

private func clarify(_ reason: String = "Which target?") -> NextToolCall {
    NextToolCall(status: .clarify, tool: nil, args: nil, rationale: "ambiguous", summary: nil, reason: reason)
}

private let clickSendArgs = #"{"element_index":0}"#
private let launchFooBarArgs = #"{"app_name":"FooBar"}"#

@MainActor
private func makeLoop(
    driver: FakeLoopDriver,
    resolver: ScriptedResolver,
    toolCallBudget: Int = VoiceCuaLoop.defaultToolCallBudget,
    observability: ObservabilityClient? = nil
) -> VoiceCuaLoop {
    VoiceCuaLoop(
        driver: driver,
        resolve: { input, createdAt, _ in await resolver.resolve(input, createdAt) },
        now: { "2026-06-22T12:00:00.000Z" },
        targetResolveDelayMs: 0,
        toolCallBudget: toolCallBudget,
        observability: observability)
}

// MARK: - Assertion helpers

private func blockedReason(_ intent: Contracts.ResolvedIntent?) -> String? {
    switch intent {
    case let .blocked(pending), let .needsClarification(pending): return pending.reason
    default: return nil
    }
}

private func resultReason(_ run: PlanRunResult?) -> String? {
    guard let result = run?.result else { return nil }
    switch result {
    case let .blocked(reason, _): return reason
    case let .failed(error, _): return error
    case .succeeded: return nil
    }
}

private func isReady(_ intent: Contracts.ResolvedIntent?) -> Bool {
    if case .ready = intent { return true }
    return false
}

private func isSatisfied(_ intent: Contracts.ResolvedIntent?) -> Bool {
    if case .satisfied = intent { return true }
    return false
}

private func isClarification(_ intent: Contracts.ResolvedIntent?) -> Bool {
    if case .needsClarification = intent { return true }
    return false
}

private func toolCallCount(_ events: [Contracts.SupervisionAuditEvent], tool: Contracts.DriverTool) -> Int {
    events.filter { event in
        if case let .toolCall(_, payload) = event { return payload.tool == tool }
        return false
    }.count
}

private func forbiddenObservabilityKey(_ records: [ObservabilityRecord]) -> String? {
    records
        .flatMap { $0.attributes.keys }
        .first(where: ObservabilityPrivacy.isForbiddenAttributeKey)
}

// MARK: - Tests

@MainActor
struct VoiceCuaLoopTests {
    // U3 characterization (a): a reversible plan auto-runs with no approve() call.
    @Test func autoRunsReversiblePlanWithoutApproval() async {
        let driver = FakeLoopDriver(windows: [focusedWindow()], windowState: windowState())
        let resolver = ScriptedResolver([act("type_text", args: #"{"text":"hello"}"#), done()])
        let loop = makeLoop(driver: driver, resolver: resolver)

        await loop.handleFinalTranscript(finalTranscript("type hello"))

        #expect(isSatisfied(loop.intent))
        #expect(loop.session?.status == .succeeded)
        #expect(await driver.recordedCalls() == ["type_text"])
    }

    // U3 characterization (b): a mutating plan waits for approve(); reject() runs no action.
    @Test func mutatingPlanWaitsForApproveAndRejectRunsNothing() async {
        let driver = FakeLoopDriver(windows: [focusedWindow()], windowState: windowState())
        let resolver = ScriptedResolver([act("click", args: clickSendArgs)])
        let loop = makeLoop(driver: driver, resolver: resolver)

        await loop.handleFinalTranscript(finalTranscript("send it"))

        // Paused at approval — the commit click escalated to mutating and did NOT dispatch.
        #expect(isReady(loop.intent))
        #expect(await driver.recordedCalls().isEmpty)

        await loop.reject()
        #expect(loop.session?.status == .rejected)
        #expect(loop.runResult?.status == .rejected)
        #expect(await driver.recordedCalls().isEmpty)
    }

    // U3 characterization (c): the loop observes window state before issuing any action.
    @Test func observesWindowStateBeforeIssuingAction() async {
        let driver = FakeLoopDriver(windows: [focusedWindow()], windowState: windowState())
        let resolver = ScriptedResolver([act("scroll"), done()])
        let loop = makeLoop(driver: driver, resolver: resolver)

        await loop.handleFinalTranscript(finalTranscript("scroll down"))

        // The first resolver input already carried the live tick-0 observation.
        let firstInput = await resolver.seenInputs().first
        #expect(firstInput?.goalSession?.observations.count == 1)
        #expect(firstInput?.goalSession?.observations.first?.state?.surface.app == "Codex")
    }

    // U3 characterization (d): a clarification never produces an action.
    @Test func clarificationNeverActs() async {
        let driver = FakeLoopDriver(windows: [focusedWindow()], windowState: windowState())
        let resolver = ScriptedResolver([clarify("Which window?")])
        let loop = makeLoop(driver: driver, resolver: resolver)

        await loop.handleFinalTranscript(finalTranscript("do the thing"))

        #expect(isClarification(loop.intent))
        #expect(loop.session?.status == .blocked)
        #expect(await driver.recordedCalls().isEmpty)
    }

    // U3 autonomous loop: a failed action feeds forward and the loop recovers, not ends blocked.
    @Test func feedsFailedActionForwardAndRecovers() async {
        let driver = FakeLoopDriver(
            windows: [focusedWindow()], windowState: windowState(),
            callResults: ["launch_app": .failed(error: "FooBar.app not found")])
        let resolver = ScriptedResolver([act("launch_app", args: launchFooBarArgs), act("scroll"), done()])
        let loop = makeLoop(driver: driver, resolver: resolver)

        await loop.handleFinalTranscript(finalTranscript("open foobar then scroll"))

        // launch_app failed, the loop fed it forward, took the resolver's alternative, and finished.
        #expect(await driver.recordedCalls() == ["launch_app", "scroll"])
        #expect(isSatisfied(loop.intent))
        #expect(loop.session?.status == .succeeded)
    }

    // U3 autonomous loop: a commit (Send) click gates mid-loop, runs after approval.
    @Test func gatesCommitClickThenRunsAfterApproval() async {
        let driver = FakeLoopDriver(windows: [focusedWindow()], windowState: windowState(commitLabel: "Send"))
        let resolver = ScriptedResolver([act("click", args: clickSendArgs), done()])
        let loop = makeLoop(driver: driver, resolver: resolver)

        await loop.handleFinalTranscript(finalTranscript("send the message"))
        #expect(isReady(loop.intent))
        #expect(await driver.recordedCalls().isEmpty)

        await loop.approve()
        #expect(await driver.recordedCalls() == ["click"])
        #expect(loop.session?.status == .succeeded)
    }

    // U3 autonomous loop: a per-call tool_call audit event is recorded for every executed action.
    @Test func recordsToolCallAuditForEveryExecutedAction() async {
        let driver = FakeLoopDriver(windows: [focusedWindow()], windowState: windowState())
        let resolver = ScriptedResolver([act("scroll"), done()])
        let loop = makeLoop(driver: driver, resolver: resolver)

        await loop.handleFinalTranscript(finalTranscript("scroll"))

        #expect(toolCallCount(loop.auditEvents, tool: .scroll) == 1)
        // The Intention Log also carries the intent_created records for both ticks.
        let intentCreated = loop.auditEvents.filter {
            if case .intentCreated = $0 { return true }
            return false
        }
        #expect(intentCreated.count == 2)
    }

    // Observability: the Swift goal loop emits local, sanitized records for remote-debuggable
    // session traces without raw transcript, prompt, app-title, or window-content fields.
    @Test func emitsSanitizedObservabilityRecordsForGoalLoop() async {
        let sink = ObservabilityMemorySink()
        let observability = ObservabilityClient(
            component: "director.loop",
            sink: sink,
            clock: { "2026-06-27T12:00:00.000Z" }
        )
        let driver = FakeLoopDriver(windows: [focusedWindow()], windowState: windowState())
        let resolver = ScriptedResolver([act("scroll"), done()])
        let loop = makeLoop(driver: driver, resolver: resolver, observability: observability)

        await loop.handleFinalTranscript(finalTranscript("scroll the page"))

        let records = await sink.records()
        let started = records.first { $0.event == "goal.session_started" }
        #expect(started?.kind == .log)
        #expect(started?.sessionId == "session-1")
        #expect(started?.correlationId == "session-1")
        #expect(started?.platform == "macos")
        #expect(started?.attributes["speech_chars"] == .number(15))
        #expect(started?.attributes["confidence"] == .number(0.95))
        #expect(started?.attributes["latency_ms"] == .number(100))

        let firstResolve = records.first { $0.event == "resolver.resolve" && $0.spanId == "resolve-0" }
        #expect(firstResolve?.kind == .span)
        #expect(firstResolve?.traceId == "goal-session-1")
        #expect(firstResolve?.durationMs?.isFinite == true)
        #expect(firstResolve?.attributes["tick"] == .number(0))
        #expect(firstResolve?.attributes["tool_catalog_size"] == .number(0))
        #expect(firstResolve?.attributes["status"] == .string("ready"))

        let actionCount = records.first { $0.name == "cua_action_count" }
        #expect(actionCount?.kind == .metric)
        #expect(actionCount?.value == 1)
        #expect(actionCount?.unit == "count")
        #expect(actionCount?.attributes["status"] == .string("succeeded"))
        #expect(records.contains { $0.event == "action.completed" && $0.stage == .actionCompleted })
        #expect(forbiddenObservabilityKey(records) == nil)
    }

    // Observability: handled driver failures produce a failure metric and error envelope while the
    // normal recovery loop still tries the resolver's next alternative.
    @Test func emitsHandledFailureObservabilityForDriverFailures() async {
        let sink = ObservabilityMemorySink()
        let observability = ObservabilityClient(
            component: "director.loop",
            sink: sink,
            clock: { "2026-06-27T12:00:00.000Z" }
        )
        let driver = FakeLoopDriver(
            windows: [focusedWindow()], windowState: windowState(),
            callResults: ["launch_app": .failed(error: "FooBar.app not found")])
        let resolver = ScriptedResolver([act("launch_app", args: launchFooBarArgs), act("scroll"), done()])
        let loop = makeLoop(driver: driver, resolver: resolver, observability: observability)

        await loop.handleFinalTranscript(finalTranscript("open foobar then scroll"))

        let records = await sink.records()
        let failureCount = records.first { $0.name == "cua_failure_count" }
        #expect(failureCount?.kind == .metric)
        #expect(failureCount?.value == 1)
        #expect(failureCount?.attributes["status"] == .string("failed"))

        let failure = records.first { $0.event == "driver.call.failed" }
        #expect(failure?.kind == .error)
        #expect(failure?.errorClass == "CuaActionFailure")
        #expect(failure?.handled == true)
        #expect(failure?.platform == "macos")
        #expect(failure?.attributes["risk"] == .string("reversible"))
        #expect(records.contains { $0.event == "action.failed" && $0.stage == .actionFailed })
        #expect(records.contains { $0.event == "action.completed" && $0.stage == .actionCompleted })
        #expect(forbiddenObservabilityKey(records) == nil)
    }

    // U3 autonomous loop: interrupt() stops the loop and finishes the session blocked.
    @Test func interruptStopsLoopAndFinishesBlocked() async {
        let driver = FakeLoopDriver(windows: [focusedWindow()], windowState: windowState())
        let resolver = ScriptedResolver([act("click", args: clickSendArgs)])
        let loop = makeLoop(driver: driver, resolver: resolver)

        // Pause at the mutating-approval boundary, then interrupt.
        await loop.handleFinalTranscript(finalTranscript("send it"))
        #expect(isReady(loop.intent))

        loop.interrupt()
        #expect(loop.session?.status == .blocked)
        #expect(blockedReason(loop.intent) == "Interrupted")
        #expect(await driver.recordedCalls().isEmpty)
    }

    // U3b full-surface: a previously-unreachable read-only tool (scroll) auto-runs through driver.call.
    @Test func autoRunsReadOnlyScrollThroughDriverCall() async {
        let driver = FakeLoopDriver(windows: [focusedWindow()], windowState: windowState())
        let resolver = ScriptedResolver([act("scroll"), done()])
        let loop = makeLoop(driver: driver, resolver: resolver)

        await loop.handleFinalTranscript(finalTranscript("scroll the page"))

        #expect(await driver.recordedCalls() == ["scroll"])
        #expect(loop.session?.status == .succeeded)
    }

    // U3b full-surface: a destructive tool (kill_app) gates until approved, then dispatches.
    @Test func gatesDestructiveKillAppUntilApproved() async {
        let driver = FakeLoopDriver(windows: [focusedWindow()], windowState: windowState())
        let resolver = ScriptedResolver([act("kill_app", args: #"{"pid":42}"#), done()])
        let loop = makeLoop(driver: driver, resolver: resolver)

        await loop.handleFinalTranscript(finalTranscript("force quit it"))
        #expect(isReady(loop.intent))
        #expect(await driver.recordedCalls().isEmpty)

        await loop.approve()
        #expect(await driver.recordedCalls() == ["kill_app"])
        #expect(loop.session?.status == .succeeded)
    }

    // U3b BUG 4: the loop stops instead of re-dispatching a call that already failed.
    @Test func stopsInsteadOfRedispatchingFailedCall() async {
        let driver = FakeLoopDriver(
            windows: [focusedWindow()], windowState: windowState(),
            callResults: ["launch_app": .failed(error: "FooBar.app not found")])
        // The resolver keeps retrying the SAME failing call.
        let resolver = ScriptedResolver([
            act("launch_app", args: launchFooBarArgs),
            act("launch_app", args: launchFooBarArgs),
        ])
        let loop = makeLoop(driver: driver, resolver: resolver)

        await loop.handleFinalTranscript(finalTranscript("open foobar"))

        // Dispatched exactly once; the repeat was blocked before reaching the driver.
        #expect(await driver.recordedCalls() == ["launch_app"])
        #expect(loop.session?.status == .blocked)
        #expect(resultReason(loop.runResult)?.contains("already failed") == true)
    }

    // Budget: the goal loop stops at the per-goal action budget.
    @Test func stopsAtActionBudget() async {
        let driver = FakeLoopDriver(windows: [focusedWindow()], windowState: windowState())
        let resolver = ScriptedResolver([act("scroll"), act("scroll"), done()])
        let loop = makeLoop(driver: driver, resolver: resolver, toolCallBudget: 1)

        await loop.handleFinalTranscript(finalTranscript("keep scrolling"))

        #expect(loop.session?.status == .blocked)
        #expect(blockedReason(loop.intent)?.contains("action budget of 1") == true)
        #expect(await driver.recordedCalls() == ["scroll"])
    }

    // Terminal: a resolver `done` decision finishes the session succeeded with no dispatch.
    @Test func doneResultFinishesSucceeded() async {
        let driver = FakeLoopDriver(windows: [focusedWindow()], windowState: windowState())
        let resolver = ScriptedResolver([done("Nothing to do")])
        let loop = makeLoop(driver: driver, resolver: resolver)

        await loop.handleFinalTranscript(finalTranscript("never mind"))

        #expect(isSatisfied(loop.intent))
        #expect(loop.session?.status == .succeeded)
        #expect(await driver.recordedCalls().isEmpty)
    }
}
