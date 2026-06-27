//
//  VoiceCuaLoop.swift
//  DirectorSidecar
//
//  Port of apps/desktop/src/features/voice-cua/useVoiceCuaController.ts (ADR 0005 Track A — the
//  loop core). This IS the engine the migration exists to preserve: the autonomous, goal-oriented
//  supervision loop — observe desktop state → resolve the next driver tool call → derive risk
//  locally → gate (auto-run / pause for approval) → dispatch through the generic driver → observe
//  again → stop on done / clarify / blocked / interrupted / budget. It also carries the engine
//  behavior the ADR calls out as non-decoration: a per-call Intention Log, the supervision session
//  lifecycle, an action budget, an always-available interrupt, and the KD2 failed-action recovery
//  floor.
//
//  React → Swift shape:
//   • `useState` (intent / runResult / session / auditEvents) → `@Observable private(set) var`.
//   • `useRef` mutable singletons (audit + session stores, the goal run, the interrupt flag, the
//     tool catalog) → plain stored properties; the stores are reference types created once.
//   • The `GoalRunState` the controller threaded through `useRef` is a value struct here, rebuilt
//     immutably each transition (no in-place mutation).
//   • The injected `driver` / `resolveIntent` / pointing context → the CuaLoopDriver / resolver /
//     IntentIntake seams (CuaLoopDriver.swift).
//
//  Dispatch, the per-call gate, effective-risk fold, and the (tool,args) dedup signature are the
//  Track B helpers (StepDispatch / ToolCallGate / ActionDedup); this file is the orchestration that
//  composes them with the live driver, exactly as the TS controller composed `@handsoff/actions`.
//

import Foundation
import Observation
import OSLog

@MainActor
@Observable
final class VoiceCuaLoop {
    // MARK: Published state (the controller's useState)

    private(set) var intent: Contracts.ResolvedIntent?
    private(set) var runResult: PlanRunResult?
    private(set) var session: Contracts.SupervisionSession?
    private(set) var auditEvents: [Contracts.SupervisionAuditEvent] = []

    // MARK: Injected dependencies (the controller's args)

    private let driver: any CuaLoopDriver
    private let resolve: NextToolCallResolving
    private let intake: any IntentIntake
    private let catalog: ToolCatalog
    private let nowProvider: (@Sendable () -> String)?
    private let targetResolveDelayMs: Int
    private let defaultToolCallBudget: Int

    // MARK: Engine singletons (the controller's useRef stores)

    private let sessions: SupervisionSessionStore
    private let audit: ActionAuditStore
    /// Phase 4 safety: the ported raise-never-lower risk policy (I9). An ADDITIONAL invariant on
    /// top of the per-call ToolCallGate — it can only RAISE the gate to approval, never relax it.
    private let riskGate = RiskGate()
    /// Phase 4 safety: the ported SHA-256 hash-chained, append-only audit log (NFR-8). Mirrors each
    /// committed step alongside the existing `audit` ActionAuditStore so commits are tamper-evident.
    private let auditChain = AuditLog()
    private var goalRun: GoalRunState?
    /// Armed by the user interrupt; the loop checks it at every await boundary and stops cleanly.
    private var interrupted = false

    /// Per-goal autonomous-loop ceiling on EXECUTED tool calls (U3 / KD6). Perception ticks are free.
    static let defaultToolCallBudget = 30
    /// Fixed retarget grace before intent resolution (the controller's DEFAULT_TARGET_RESOLVE_DELAY_MS).
    static let defaultTargetResolveDelayMs = 1500

    init(
        driver: any CuaLoopDriver,
        resolve: @escaping NextToolCallResolving,
        intake: any IntentIntake = SpeechOnlyIntake(),
        now: (@Sendable () -> String)? = nil,
        targetResolveDelayMs: Int = VoiceCuaLoop.defaultTargetResolveDelayMs,
        toolCallBudget: Int = VoiceCuaLoop.defaultToolCallBudget,
        replayStore: SupervisionReplayStore? = nil
    ) {
        self.driver = driver
        self.resolve = resolve
        self.intake = intake
        self.catalog = ToolCatalog(driver: driver)
        self.nowProvider = now
        self.targetResolveDelayMs = targetResolveDelayMs
        self.defaultToolCallBudget = toolCallBudget
        self.sessions = SupervisionSessionStore(replay: replayStore)
        self.audit = ActionAuditStore(replay: replayStore)
    }

    // MARK: Public surface (the controller's returned handle)

    /// `handleFinalTranscript`: the goal-loop entry point. Awaits the loop to its next rest state —
    /// a terminal status (satisfied/blocked) OR an approval pause (a mutating tick set as the ready
    /// `intent`, awaiting `approve()`/`reject()`). The TS fired this and forgot; awaiting it here
    /// makes the loop deterministically testable.
    func handleFinalTranscript(_ finalTranscript: Contracts.FinalTranscript) async {
        await createIntent(finalTranscript)
    }

    // MARK: Per-goal run state (the controller's GoalRunState, lifted out of useRef)

    private struct GoalRunState {
        let sessionId: String
        let baseInput: Contracts.IntentInput
        let observations: [Contracts.GoalLoopObservation]
        let nextTick: Int
        let toolCalls: Int
        let toolCallBudget: Int
        let referent: Contracts.SelectedReferent?
        let failedSignatures: FailedActionMemory
    }

    // MARK: Intake

    private func createIntent(_ finalTranscript: Contracts.FinalTranscript) async {
        interrupted = false
        DirectorDiagnostics.loop.info("goal intake final_transcript_chars=\(finalTranscript.text.count, privacy: .public)")
        await wait(targetResolveDelayMs)
        let createdAt = timestamp()
        let started = sessions.start(createdAt)

        let input = await intake.makeInput(for: finalTranscript, sessionId: started.id)
        let run = GoalRunState(
            sessionId: started.id,
            baseInput: input,
            observations: [],
            nextTick: 0,
            toolCalls: 0,
            toolCallBudget: defaultToolCallBudget,
            referent: nil,
            failedSignatures: FailedActionMemory())
        goalRun = run
        session = started
        await continueGoal(run, createdAt)
    }

    // MARK: Observation

    private func observeGoalTick(
        _ tick: Int,
        _ previousAction: Contracts.GoalLoopObservation.PreviousAction?
    ) async -> Contracts.GoalLoopObservation {
        let capturedAt = timestamp()
        let windows: [CuaWindow]
        if case let .succeeded(value) = await driver.listWindows() {
            windows = value
        } else {
            windows = []
        }
        let focused = windows.first(where: \.focused) ?? windows.first
        var state: Contracts.CuaWindowState?
        if let focused {
            if case let .succeeded(value) = await driver.getWindowState(pid: focused.pid, windowId: focused.windowId) {
                state = value.asContractState
            }
        }
        DirectorDiagnostics.loop.info("observed tick=\(tick, privacy: .public) windows=\(windows.count, privacy: .public) focused=\(focused?.app ?? "none", privacy: .public) state_elements=\(state?.elementCount ?? 0, privacy: .public)")
        return Contracts.GoalLoopObservation(
            tick: tick,
            capturedAt: capturedAt,
            windows: windows.map(\.surface),
            state: state,
            previousAction: previousAction)
    }

    /// Build the resolver input for one tick. Tick 0 carries the base input + goal session; later
    /// ticks ground on the latest live observation (active-window pointing evidence + candidates).
    private func inputForTick(
        _ run: GoalRunState,
        _ tick: Int,
        _ observations: [Contracts.GoalLoopObservation]
    ) -> Contracts.IntentInput {
        let goalSession = Contracts.GoalSessionInput(
            goal: run.baseInput.finalTranscript.text, tick: tick, observations: observations)
        if tick == 0 {
            return run.baseInput.with(goalSession: goalSession)
        }
        let latest = observations.last
        let surface = latest?.state?.surface ?? latest?.windows.first
        var pointing: [Contracts.PointingEvidence] = surface.map {
            [Contracts.PointingEvidence(
                source: .activeWindow, confidence: 1, strategy: "goal-loop-live-observation",
                surface: $0, cursor: nil)]
        } ?? run.baseInput.pointingEvidence
        // #147: re-inject the carried referent as pointing evidence so the resolver re-sees the
        // previously bound deictic target across ticks — the live-observation rebuild above would
        // otherwise drop it, losing the binding. No coordinates are fabricated: the referent's own
        // source + confidence carry it forward and its id rides in `strategy`; surface/cursor stay
        // nil (a SelectedReferent has no bounds to invent).
        if let referent = run.referent {
            pointing.append(Contracts.PointingEvidence(
                source: referent.source.asPointingSource,
                confidence: referent.confidence,
                strategy: "goal-loop-carried-referent:\(referent.id)",
                surface: nil, cursor: nil))
        }
        let candidates = (latest?.windows.isEmpty == false) ? latest!.windows : run.baseInput.surfaceCandidates
        return run.baseInput.with(
            pointingEvidence: pointing, surfaceCandidates: candidates, goalSession: goalSession)
    }

    // MARK: Audit

    private func recordIntent(_ sessionId: String, _ createdAt: String, _ next: Contracts.ResolvedIntent) {
        let actionId: String
        if case let .ready(ready) = next { actionId = ready.actionPlan.id } else { actionId = next.id }
        audit.record(.intentCreated(
            .init(sessionId: sessionId, actionId: actionId, recordedAt: createdAt), intent: next))
        auditEvents = audit.forSession(sessionId)
    }

    /// Per-call Intention Log record (U3 / KD6): one `tool_call` event per step in the executed
    /// tick, carrying the transcript that drove it, the bound referent, the locally-derived risk +
    /// approval state, and the typed result.
    private func recordToolCalls(
        _ run: GoalRunState,
        _ readyIntent: Contracts.ResolvedIntent.Ready,
        _ observation: Contracts.GoalLoopObservation?,
        _ approval: Contracts.SupervisionAuditEvent.ToolCallApproval,
        _ result: Contracts.CuaActionResult,
        _ recordedAt: String
    ) {
        for step in readyIntent.actionPlan.actionPlan {
            let tool = StepDispatch.driverToolForStep(step)
            let target = StepDispatch.toolCallTargetForStep(step, observation)
            audit.record(.toolCall(
                .init(sessionId: run.sessionId, actionId: readyIntent.actionPlan.id, recordedAt: recordedAt),
                .init(
                    transcript: run.baseInput.finalTranscript.text,
                    referent: readyIntent.referent ?? run.referent,
                    tool: tool,
                    target: target,
                    risk: Contracts.ToolRisk.riskForToolName(StepDispatch.toolNameForStep(step), target: target),
                    approval: approval,
                    result: result)))
        }
        auditEvents = audit.forSession(run.sessionId)
    }

    private func finishGoal(_ run: GoalRunState, _ status: TerminalSessionStatus, _ finishedAt: String) {
        session = sessions.finish(run.sessionId, status, finishedAt)
        goalRun = nil
    }

    /// Stop the loop cleanly when interrupted. Returns true when the caller should bail. Records the
    /// blocked intent + finishes the session only once — if a synchronous `interrupt()` already tore
    /// the run down, the caller still bails but does not double-record.
    private func stopIfInterrupted(_ run: GoalRunState, _ input: Contracts.IntentInput, at: String) -> Bool {
        guard interrupted else { return false }
        guard goalRun != nil else { return true }
        let next = blockedIntent(input, id: "intent-interrupted-\(run.nextTick)", at, "Interrupted")
        intent = next
        runResult = nil
        recordIntent(run.sessionId, at, next)
        finishGoal(run, .blocked, at)
        return true
    }

    // MARK: The loop

    private func continueGoal(
        _ run: GoalRunState,
        _ createdAt: String,
        _ previousAction: Contracts.GoalLoopObservation.PreviousAction? = nil
    ) async {
        if stopIfInterrupted(run, inputForTick(run, run.nextTick, run.observations), at: createdAt) { return }
        if run.toolCalls >= run.toolCallBudget {
            let input = inputForTick(run, run.nextTick, run.observations)
            let next = blockedIntent(
                input, id: "intent-budget-\(run.nextTick)", createdAt,
                "Goal loop reached the action budget of \(run.toolCallBudget)")
            intent = next
            runResult = nil
            recordIntent(run.sessionId, createdAt, next)
            finishGoal(run, .blocked, createdAt)
            return
        }

        let observation = await observeGoalTick(run.nextTick, previousAction)
        let observations = run.observations + [observation]
        let input = inputForTick(run, run.nextTick, observations)
        if stopIfInterrupted(run, input, at: timestamp()) { return }

        let tools = await catalog.loadedTools()
        let resolved = await resolve(input, createdAt, tools)
        if stopIfInterrupted(run, input, at: timestamp()) { return }
        DirectorDiagnostics.loop.info("resolver returned \(Self.intentSummary(resolved), privacy: .public)")

        // The gate (U2/KD3) re-derives risk per call from the actual tool each step reaches —
        // escalating a commit click, never trusting a model downgrade. Reflect that effective risk
        // on the displayed ready intent so the approval surface and the loop's pause agree.
        let next: Contracts.ResolvedIntent
        if case let .ready(ready) = resolved {
            next = .ready(StepDispatch.withEffectiveRisk(
                ready, risk: StepDispatch.planToolRisk(ready.actionPlan, observation)))
        } else {
            next = resolved
        }
        intent = next
        if !next.isSatisfied { runResult = nil }
        recordIntent(run.sessionId, createdAt, next)

        if next.isSatisfied {
            DirectorDiagnostics.loop.info("goal satisfied session=\(run.sessionId, privacy: .public)")
            finishGoal(run, .succeeded, createdAt)
            return
        }
        guard case let .ready(readyNext) = next else {
            DirectorDiagnostics.loop.warning("goal blocked session=\(run.sessionId, privacy: .public) \(Self.intentSummary(next), privacy: .public)")
            finishGoal(run, .blocked, createdAt)
            return
        }

        // Carry the referent the resolver bound this tick so later ticks + the per-call audit keep
        // the deictic provenance.
        let nextRun = GoalRunState(
            sessionId: run.sessionId,
            baseInput: run.baseInput,
            observations: observations,
            nextTick: run.nextTick + 1,
            toolCalls: run.toolCalls,
            toolCallBudget: run.toolCallBudget,
            referent: readyNext.referent ?? run.referent,
            failedSignatures: run.failedSignatures)
        goalRun = nextRun

        // Read-only / reversible auto-run; mutating / destructive pause for approval. The pause is
        // held by returning here with the ready intent set — `approve()` resumes, `reject()` ends.
        if readyNext.riskLevel.requiresApproval {
            DirectorDiagnostics.loop.notice("approval required session=\(run.sessionId, privacy: .public) risk=\(readyNext.riskLevel.rawValue, privacy: .public)")
            return
        }
        await runGoalAction(nextRun, readyNext, observation)
    }

    private func runGoalAction(
        _ run: GoalRunState,
        _ readyIntent: Contracts.ResolvedIntent.Ready,
        _ observation: Contracts.GoalLoopObservation?,
        approved: Bool = false
    ) async {
        if stopIfInterrupted(run, readyIntent.input, at: timestamp()) { return }
        let runningAt = timestamp()
        let approvalState: Contracts.SupervisionAuditEvent.ToolCallApproval = approved ? .approved : .auto

        // Loop-dedup guard (KD2 recovery floor): refuse to re-dispatch a (tool,args) that already
        // failed this goal — stop with a clear blocked reason instead of looping the dead action to
        // the budget. Only verbatim-failed signatures are blocked, so a genuine alternative runs.
        if let repeated = run.failedSignatures.firstRepeated(in: readyIntent.actionPlan.actionPlan) {
            let result = ActionDedup.repeatedCallBlock(repeated)
            DirectorDiagnostics.loop.warning("dedup blocked repeated action session=\(run.sessionId, privacy: .public)")
            session = sessions.run(run.sessionId, runningAt)
            recordToolCalls(run, readyIntent, observation, approvalState, result, runningAt)
            runResult = PlanRunResult(status: .blocked, result: result)
            finishGoal(run, .blocked, runningAt)
            return
        }

        // Phase 4 safety: the ported RiskGate (I9) — an ADDITIONAL raise-never-lower invariant on
        // top of the per-call gate below (NOT a replacement; the StepDispatch guard still runs). It
        // re-derives each step's risk floor from the verb alone (the model may only RAISE it), so an
        // unapproved step whose blast radius needs a greenlight blocks the whole tick here before any
        // dispatch. Gating only applies when there is no approval; an approved run skips it, exactly
        // like the per-call gate — so RiskGate can only ever raise the gate, never lower it.
        if !approved {
            for step in readyIntent.actionPlan.actionPlan {
                let verb = riskGateVerb(for: step)
                let call = ToolCall(verb: verb, args: [], modelClaimedRisk: readyIntent.actionPlan.riskLevel)
                if riskGate.gateToolCall(call).decision == .requiresApproval {
                    let blocked = Contracts.CuaActionResult.blocked(
                        reason: "RiskGate requires approval for \(verb)", state: nil)
                    DirectorDiagnostics.loop.notice("riskgate blocked action session=\(run.sessionId, privacy: .public) verb=\(verb, privacy: .public)")
                    session = sessions.run(run.sessionId, runningAt)
                    recordToolCalls(run, readyIntent, observation, approvalState, blocked, runningAt)
                    runResult = PlanRunResult(status: .blocked, result: blocked)
                    finishGoal(run, .blocked, runningAt)
                    return
                }
            }
        }

        // Per-call gate (U2): ask the gate for EVERY step before dispatch, deriving the gate from
        // the real tool + target, never the model's claim. A commit step with no matching approval
        // blocks the whole tick here — the typed dispatch never runs.
        if let blocked = StepDispatch.firstBlockedStep(readyIntent.actionPlan.actionPlan, observation, approved: approved) {
            DirectorDiagnostics.loop.notice("gate blocked action session=\(run.sessionId, privacy: .public) approved=\(approved, privacy: .public)")
            session = sessions.run(run.sessionId, runningAt)
            recordToolCalls(run, readyIntent, observation, approvalState, blocked, runningAt)
            runResult = PlanRunResult(status: .blocked, result: blocked)
            finishGoal(run, .blocked, runningAt)
            return
        }

        session = sessions.run(run.sessionId, runningAt)
        runResult = PlanRunResult(status: .running)
        // Dispatch every step through the GENERIC driver passthrough (`driver.call`, U1) so the full
        // 36-tool surface is reachable. Stop at the first failure and feed it forward for recovery.
        let (actionResult, failedSignature) = await dispatchPlan(readyIntent.actionPlan.actionPlan)
        recordToolCalls(run, readyIntent, observation, approvalState, actionResult, runningAt)
        runResult = PlanRunResult.fromActionResult(actionResult)
        auditEvents = audit.forSession(run.sessionId)

        // Phase 4 safety: mirror each committed step into the hash-chained, append-only AuditLog
        // (NFR-8 tamper-evidence) alongside the existing ActionAuditStore. `append` stamps the chain
        // link, so we pass empty prevHash/hash and let it fill them. `verified` is the dispatch's
        // success; `conf` carries the bound referent's confidence (else 1.0).
        let verified: Bool = { if case .succeeded = actionResult { return true } else { return false } }()
        let conf = readyIntent.referent?.confidence ?? run.referent?.confidence ?? 1.0
        for step in readyIntent.actionPlan.actionPlan {
            let verb = riskGateVerb(for: step)
            let args = auditArgs(for: step)
            let taint: Taint = args.contains { $0.taint == .attacker_influenceable } ? .attacker_influenceable : .trusted
            auditChain.append(AuditEntry(
                action: verb, args: args, taint: taint, conf: conf, verified: verified,
                undoToken: UndoToken(id: run.sessionId + step.id, action: verb),
                prevHash: "", hash: ""))
        }

        let ranRun = GoalRunState(
            sessionId: run.sessionId,
            baseInput: run.baseInput,
            observations: run.observations,
            nextTick: run.nextTick,
            toolCalls: run.toolCalls + readyIntent.actionPlan.actionPlan.count,
            toolCallBudget: run.toolCallBudget,
            referent: run.referent,
            // Remember a failed (tool,args) so the dedup guard won't re-dispatch it next turn.
            failedSignatures: run.failedSignatures.recording(failedSignature))
        goalRun = ranRun

        if stopIfInterrupted(ranRun, readyIntent.input, at: timestamp()) { return }

        // Recovery (KD2): a failed action is a normal observation, not the end of the goal. Feed the
        // failure forward so the resolver tries an alternative; only an exhausted budget / interrupt
        // / a resolver-emitted blocked|done ends the loop.
        await continueGoal(ranRun, timestamp(), .init(
            actionId: readyIntent.actionPlan.id, result: actionResult))
    }

    /// Execute a tick's steps in order through `driver.call`, normalizing each driver result. Stops
    /// at the first non-success so a failed step is surfaced for recovery; the last step's result
    /// represents the tick. The contract `tool_call.args` are bridged onto the driver-passthrough
    /// `JSONValue` family at the boundary (PORTING.md notes 4/6).
    private func dispatchPlan(
        _ steps: [Contracts.ActionStep]
    ) async -> (result: Contracts.CuaActionResult, failedSignature: String?) {
        var last = Contracts.CuaActionResult.succeeded(summary: "No action", state: nil)
        for step in steps {
            let (tool, args) = StepDispatch.driverCallForStep(step)
            DirectorDiagnostics.loop.info("dispatch tool=\(tool, privacy: .public) arg_keys=\(args.keys.sorted().joined(separator: ","), privacy: .public)")
            let callResult = await driver.call(tool: tool, input: .object(args.mapValues(\.asDriverValue)))
            last = cuaResultToActionResult(callResult, summary: "Called \(tool)")
            guard case .succeeded = last else {
                DirectorDiagnostics.loop.error("dispatch failed tool=\(tool, privacy: .public) result=\(Self.actionResultSummary(last), privacy: .public)")
                return (last, ActionDedup.callSignature(step))
            }
            DirectorDiagnostics.loop.info("dispatch succeeded tool=\(tool, privacy: .public)")
        }
        return (last, nil)
    }

    // MARK: Approval surface

    func approve() async {
        guard case let .ready(ready) = intent, session != nil, let run = goalRun else { return }
        DirectorDiagnostics.loop.notice("approval accepted session=\(run.sessionId, privacy: .public)")
        await runGoalAction(run, ready, run.observations.last, approved: true)
    }

    func reject() async {
        guard case let .ready(ready) = intent, let currentSession = session else { return }
        let decidedAt = timestamp()
        // Rejection runs NOTHING: no tool call is dispatched. Record the rejected call(s) for the
        // audit trail and end the session rejected.
        let rejected = Contracts.CuaActionResult.blocked(reason: "Rejected before execution", state: nil)
        if let run = goalRun {
            DirectorDiagnostics.loop.notice("approval rejected session=\(run.sessionId, privacy: .public)")
            recordToolCalls(run, ready, run.observations.last, .rejected, rejected, decidedAt)
        }
        audit.record(.executionFinished(
            .init(sessionId: currentSession.id, actionId: ready.actionPlan.id, recordedAt: decidedAt),
            status: .rejected, result: nil))
        session = sessions.finish(currentSession.id, .rejected, decidedAt)
        goalRun = nil
        runResult = PlanRunResult(status: .rejected)
        auditEvents = audit.forSession(currentSession.id)
    }

    /// Always-available interrupt (KD6): cancel the in-flight loop, clear the pending-approval
    /// state, finish the session blocked. The loop checks the flag at every await boundary; an
    /// interrupt with nothing pending just arms the flag so an in-flight tick stops on its next
    /// boundary.
    func interrupt() {
        interrupted = true
        guard let run = goalRun else { return }
        DirectorDiagnostics.loop.notice("goal interrupted session=\(run.sessionId, privacy: .public)")
        if let currentSession = session, currentSession.status != .succeeded, currentSession.status != .blocked {
            let at = timestamp()
            let input = inputForTick(run, run.nextTick, run.observations)
            let next = blockedIntent(input, id: "intent-interrupted-\(run.nextTick)", at, "Interrupted")
            intent = next
            runResult = nil
            recordIntent(run.sessionId, at, next)
            finishGoal(run, .blocked, at)
        }
    }

    // MARK: Helpers

    /// Phase 4 safety: the verb the RiskGate keys its blast-radius floor off. The typed kinds map to
    /// their own wire verb; a `tool_call` uses its validated driver tool's wire name. (Distinct from
    /// StepDispatch.toolNameForStep, which folds inspect/screenshot onto get_window_state — RiskGate
    /// classifies them as their own read-only verbs.)
    private func riskGateVerb(for step: Contracts.ActionStep) -> String {
        switch step {
        case let .toolCall(_, _, tool, _): return tool.rawValue
        case .clickElement: return "click"
        case .typeText: return "type_text"
        case .setValue: return "set_value"
        case .inspectWindowState: return "inspect_window_state"
        case .captureScreenshot: return "capture_screenshot"
        case .launchApp: return "launch_app"
        }
    }

    /// Phase 4 safety: the audit-log args for a committed step. Only a `tool_call` carries readily
    /// ActionArg-typed flat args (mapped trusted — on-device perception); the typed kinds commit with
    /// no arg list here ([] is acceptable per NFR-8's evidence shape).
    private func auditArgs(for step: Contracts.ActionStep) -> [ActionArg] {
        guard case let .toolCall(_, _, _, args) = step else { return [] }
        return args.keys.sorted().map { key in
            ActionArg(name: key, value: Self.auditArgValue(args[key]!), taint: .trusted)
        }
    }

    /// A flat string form of a `tool_call` arg value for the audit fingerprint.
    private static func auditArgValue(_ value: Contracts.JSONValue) -> String {
        switch value {
        case .null: return "null"
        case let .bool(b): return String(b)
        case let .number(n): return String(n)
        case let .string(s): return s
        case let .array(a): return "[\(a.count)]"
        case let .object(o): return "{\(o.count)}"
        }
    }

    /// The controller's local `blockedIntent` (always status "blocked"): a terminal non-ready intent
    /// with no gate and no agent.
    private func blockedIntent(
        _ input: Contracts.IntentInput, id: String, _ createdAt: String, _ reason: String
    ) -> Contracts.ResolvedIntent {
        Contracts.ResolvedIntent.blockedIntent(
            status: .blocked, input: input, id: id, createdAt: createdAt, reason: reason)
    }

    private func timestamp() -> String {
        if let nowProvider { return nowProvider() }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }

    private func wait(_ ms: Int) async {
        guard ms > 0 else { return }
        try? await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000)
    }

    private static func intentSummary(_ intent: Contracts.ResolvedIntent) -> String {
        switch intent {
        case let .ready(ready):
            let tools = ready.actionPlan.actionPlan.map(StepDispatch.toolNameForStep).joined(separator: ",")
            return "ready risk=\(ready.riskLevel.rawValue) approval=\(ready.requiresApproval) tools=\(tools)"
        case let .needsClarification(pending):
            return "clarification reason=\(DirectorDiagnostics.clipped(pending.reason, max: 160))"
        case let .blocked(pending):
            return "blocked reason=\(DirectorDiagnostics.clipped(pending.reason, max: 160))"
        case let .satisfied(satisfied):
            return "satisfied summary=\(DirectorDiagnostics.clipped(satisfied.summary, max: 160))"
        }
    }

    private static func actionResultSummary(_ result: Contracts.CuaActionResult) -> String {
        switch result {
        case let .succeeded(summary, _): return "succeeded \(DirectorDiagnostics.clipped(summary, max: 160))"
        case let .failed(error, _): return "failed \(DirectorDiagnostics.clipped(error, max: 160))"
        case let .blocked(reason, _): return "blocked \(DirectorDiagnostics.clipped(reason, max: 160))"
        }
    }
}

// #147: map a persisted referent's modality onto the resolver's pointing-evidence source so a
// carried referent re-enters the resolver as the same deictic source it was originally bound from.
private extension Contracts.ReferentSource {
    var asPointingSource: Contracts.PointingEvidence.Source {
        switch self {
        case .gesture: return .gesture
        case .gaze: return .gaze
        case .head: return .head
        case .fusion: return .fusion
        }
    }
}
