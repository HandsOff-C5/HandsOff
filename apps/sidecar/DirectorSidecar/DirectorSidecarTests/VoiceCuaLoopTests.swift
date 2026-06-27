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
    /// When non-empty, `getWindowState` walks this sequence (repeating the last) so a test can model a
    /// window that DOES change after an action — proving the #158 no-progress detection clears.
    private let stateSequence: [CuaWindowState]
    private var stateCursor = 0
    private let tools: [DriverToolDefinition]
    private let callResults: [String: CuaResult<JSONValue>]
    private(set) var genericCalls: [String] = []
    private(set) var genericInputs: [JSONValue] = []

    init(
        windows: [CuaWindow],
        windowState: CuaWindowState?,
        stateSequence: [CuaWindowState] = [],
        tools: [DriverToolDefinition] = [],
        callResults: [String: CuaResult<JSONValue>] = [:]
    ) {
        self.windows = windows
        self.windowState = windowState
        self.stateSequence = stateSequence
        self.tools = tools
        self.callResults = callResults
    }

    func listWindows() -> CuaResult<[CuaWindow]> { .succeeded(windows) }

    func getWindowState(pid: Int, windowId: Int) -> CuaResult<CuaWindowState> {
        if !stateSequence.isEmpty {
            let state = stateSequence[min(stateCursor, stateSequence.count - 1)]
            stateCursor += 1
            return .succeeded(state)
        }
        return windowState.map { .succeeded($0) } ?? .failed(error: "no window state")
    }

    func listTools() -> CuaResult<[DriverToolDefinition]> { .succeeded(tools) }

    func call(tool: String, input: JSONValue) -> CuaResult<JSONValue> {
        genericCalls.append(tool)
        genericInputs.append(input)
        // Route a click by its addressing mode so a test can script different AX vs coordinate
        // results: a coordinate click (carries `x`) looks up `<tool>@coord` first.
        let key = Self.isCoordinate(input) ? "\(tool)@coord" : tool
        return callResults[key] ?? callResults[tool] ?? .succeeded(.object([:]))
    }

    func recordedCalls() -> [String] { genericCalls }
    func recordedInputs() -> [JSONValue] { genericInputs }

    static func isCoordinate(_ input: JSONValue) -> Bool {
        if case let .object(fields) = input { return fields["x"] != nil || fields["y"] != nil }
        return false
    }
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

/// A reversible (auto-running) click target WITH a frame — a non-commit row like a System Settings
/// sidebar entry. `capturedAt` is fixed so a repeated observation is byte-identical (the #158 no-op).
private func batteryState() -> CuaWindowState {
    CuaWindowState(
        surface: focusedWindow(),
        capturedAt: "2026-06-22T12:00:00.000Z",
        elementCount: 1,
        elements: [CuaElement(
            id: "s0001:0", index: 0, role: "AXStaticText", label: "Battery", value: nil,
            frame: Contracts.CuaElementFrame(x: 10, y: 40, width: 100, height: 20),
            parentIndex: nil, depth: 1, token: "s0001:0")])
}

/// A DIFFERENT window state — used after a click to prove a navigation (window changed) clears the
/// no-progress escalation instead of falling back to a coordinate click.
private func settingsPaneState() -> CuaWindowState {
    CuaWindowState(
        surface: focusedWindow(),
        capturedAt: "2026-06-22T12:00:05.000Z",
        elementCount: 1,
        elements: [CuaElement(
            id: "s0002:0", index: 0, role: "AXStaticText", label: "Battery Health", value: "Good",
            frame: Contracts.CuaElementFrame(x: 10, y: 40, width: 200, height: 20),
            parentIndex: nil, depth: 1, token: "s0002:0")])
}

/// A reversible click that cites the battery row by token AND index + pid/window_id (so risk derives
/// the element and it auto-runs, and `clickTargetKey`/coordinate fallback can resolve it).
private let clickBatteryArgs = #"{"element_index":0,"element_token":"s0001:0","pid":42,"window_id":7}"#

/// Whether a recorded driver input addressed an element by coordinates (the CGEvent fallback path).
private func isCoordinateInput(_ input: JSONValue) -> Bool { FakeLoopDriver.isCoordinate(input) }

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
    sink: (any ToolCallSink)? = nil
) -> VoiceCuaLoop {
    VoiceCuaLoop(
        driver: driver,
        resolve: { input, createdAt, _ in await resolver.resolve(input, createdAt) },
        now: { "2026-06-22T12:00:00.000Z" },
        targetResolveDelayMs: 0,
        toolCallBudget: toolCallBudget,
        toolCallSink: sink)
}

/// An in-memory `ToolCallSink` capturing every persisted record, for the durable-sink assertions.
private final class RecordingSink: ToolCallSink, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [ToolCallJournalEntry] = []
    func record(_ entry: ToolCallJournalEntry) { lock.lock(); stored.append(entry); lock.unlock() }
    var entries: [ToolCallJournalEntry] { lock.lock(); defer { lock.unlock() }; return stored }
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

    // #158 (a): an AX click the driver ACCEPTS but that leaves the window unchanged (Catalyst no-op)
    // escalates the SAME target to a coordinate (CGEvent) click next turn, then the no-progress floor
    // stops it — instead of spinning the identical element_index click to the budget (the 41-turn bug).
    @Test func silentNoOpClickEscalatesToCoordinateThenStops() async {
        let driver = FakeLoopDriver(windows: [focusedWindow()], windowState: batteryState())
        // The resolver re-issues the identical reversible click each turn (it sees "succeeded" + an
        // unchanged screen, so it never self-corrects — exactly the observed failure mode).
        let resolver = ScriptedResolver(Array(repeating: act("click", args: clickBatteryArgs), count: 6))
        let loop = makeLoop(driver: driver, resolver: resolver)

        await loop.handleFinalTranscript(finalTranscript("go to battery"))

        let inputs = await driver.recordedInputs()
        // First dispatch AX; after the no-op the loop escalates the same target to the coordinate
        // path; the floor stops it at maxNoProgressRepeats — far short of the 30-call budget.
        #expect(await driver.recordedCalls() == ["click", "click", "click"])
        #expect(isCoordinateInput(inputs[0]) == false)  // AX (element_index)
        #expect(isCoordinateInput(inputs[1]) == true)   // coordinate fallback (x,y)
        #expect(isCoordinateInput(inputs[2]) == true)
        #expect(loop.session?.status == .blocked)
        #expect(resultReason(loop.runResult)?.contains("no-op'd") == true)
    }

    // #158 (b): an EXPLICIT AX failure (Catalyst AXConfirm → -25200) retries as a coordinate click at
    // the element's frame center SAME turn — the refused AX action can't have acted, so a real mouse
    // click can't double-fire. The coordinate click succeeds and the loop proceeds, no spin.
    @Test func explicitAxClickFailureRetriesCoordinateSameTurn() async {
        let driver = FakeLoopDriver(
            windows: [focusedWindow()], windowState: batteryState(),
            callResults: [
                "click": .failed(error: "AX action failed: AXUIElementPerformAction(AXConfirm) returned -25200"),
                "click@coord": .succeeded(.object([:])),
            ])
        let resolver = ScriptedResolver([act("click", args: clickBatteryArgs), done()])
        let loop = makeLoop(driver: driver, resolver: resolver)

        await loop.handleFinalTranscript(finalTranscript("go to battery"))

        let inputs = await driver.recordedInputs()
        #expect(await driver.recordedCalls() == ["click", "click"])
        #expect(isCoordinateInput(inputs[0]) == false)  // AX attempt, refused
        #expect(isCoordinateInput(inputs[1]) == true)   // coordinate retry, same turn
        #expect(isSatisfied(loop.intent))
        #expect(loop.session?.status == .succeeded)
    }

    // #158 (c): a click that DOES change the window stays on the AX path — no coordinate fallback, no
    // floor. Proves the escalation only fires on a real no-op and doesn't regress working clicks.
    @Test func clickThatChangesWindowStaysOnAxPath() async {
        let driver = FakeLoopDriver(
            windows: [focusedWindow()], windowState: nil,
            stateSequence: [batteryState(), settingsPaneState(), settingsPaneState()])
        let resolver = ScriptedResolver([act("click", args: clickBatteryArgs), done()])
        let loop = makeLoop(driver: driver, resolver: resolver)

        await loop.handleFinalTranscript(finalTranscript("go to battery"))

        let inputs = await driver.recordedInputs()
        #expect(await driver.recordedCalls() == ["click"])   // one dispatch only
        #expect(isCoordinateInput(inputs[0]) == false)        // on the AX path
        #expect(isSatisfied(loop.intent))
        #expect(loop.session?.status == .succeeded)
    }

    // #158 observability: every executed tool call is mirrored to the durable sink (args + result),
    // not just the in-memory Intention Log.
    @Test func persistsEachToolCallToTheDurableSink() async {
        let sink = RecordingSink()
        let driver = FakeLoopDriver(windows: [focusedWindow()], windowState: windowState())
        let resolver = ScriptedResolver([act("scroll"), done()])
        let loop = makeLoop(driver: driver, resolver: resolver, sink: sink)

        await loop.handleFinalTranscript(finalTranscript("scroll"))

        #expect(sink.entries.count == 1)
        #expect(sink.entries.first?.tool == "scroll")
        #expect(sink.entries.first?.resultStatus == "succeeded")
        #expect(sink.entries.first?.sessionId == loop.session?.id)
    }
}
