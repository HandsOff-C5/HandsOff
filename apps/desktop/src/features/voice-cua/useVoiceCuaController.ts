import {
  driverCallForStep,
  driverToolForStep,
  firstBlockedStep,
  planToolRisk,
  toolCallTargetForStep,
  toolNameForStep,
  withEffectiveRisk,
  type PlanRunResult,
} from "@handsoff/actions";
import {
  riskForToolName,
  riskLevelRequiresApproval,
  type ActionStep,
  type CuaActionResult,
  type CuaWindow,
  type DriverToolDefinition,
  type FinalTranscript,
  type GoalLoopObservation,
  type IntentInput,
  type ResolvedIntent,
  type SelectedReferent,
  type SupervisionAuditEvent,
  type SurfaceSnapshot,
  safeParseObservabilityRecord,
  type ObservabilityRecord,
} from "@handsoff/contracts";
import { createToolCatalog, cuaResultToActionResult, type CuaDriver } from "@handsoff/cua";
import { resolveNextToolCall, type AttentionWindow } from "@handsoff/intent";
import {
  createActionAuditStore,
  createSupervisionSessionStore,
  type SupervisionSession,
  type TerminalSessionStatus,
} from "@handsoff/supervision";
import { useRef, useState } from "react";

import { makeApprovalDecision } from "../plan-preview/usePlanApproval";
import type { HeadPointingSnapshot } from "../head-pointing/useHeadPointing";
import { buildPointingEvidence, type PointingContext } from "./buildPointingEvidence";
import type { NextToolCallResolver } from "./intentResolver";

const ACTIVE_WINDOW_SURFACE: SurfaceSnapshot = {
  id: "active-window",
  title: "Active window",
  app: "Current app",
  availability: "available",
  accessStatus: "accessible",
};

// ponytail: fixed retarget grace; make it configurable if manual testing proves one size wrong.
const DEFAULT_TARGET_RESOLVE_DELAY_MS = 1500;
// Per-goal autonomous-loop ceiling (U3 / KD6): the maximum number of executed
// tool calls one utterance may drive before the loop stops with a clear blocked
// reason, so a misfiring loop cannot run away. Perception (get_window_state /
// list_windows) is free and not counted — only the agent's chosen actions are.
// Replaces the old fixed `maxTicks=5`. Overridable via the `toolCallBudget` prop.
const DEFAULT_TOOL_CALL_BUDGET = 30;
const OBSERVABILITY_COMPONENT = "desktop.voice-cua";

type ObservabilitySink = {
  emit(record: ObservabilityRecord): void;
};

type ObservabilityOptions = {
  sink?: ObservabilitySink;
  analyticsConsent?: boolean;
  release?: string;
  platform?: string;
};

type ObservabilityAttributes = Record<string, string | number | boolean | null>;

const defaultObservabilitySink: ObservabilitySink = {
  emit(record) {
    console.info("[handsoff.observability]", record);
  },
};

function wait(ms: number): Promise<void> {
  return ms > 0 ? new Promise((resolve) => setTimeout(resolve, ms)) : Promise.resolve();
}

function elapsedMs(startedAt: string, finishedAt: string): number {
  const start = Date.parse(startedAt);
  const finish = Date.parse(finishedAt);
  if (!Number.isFinite(start) || !Number.isFinite(finish)) return 0;
  return Math.max(0, finish - start);
}

function actionErrorClass(result: CuaActionResult): string {
  if (result.status === "failed") return "CuaDriverError";
  if (result.status === "blocked") return "CuaBlocked";
  return "CuaActionError";
}

// A stable (tool, args) signature for loop-dedup (KD2): the actual driver call a
// step dispatches, with args' keys sorted so the same logical call always hashes
// the same regardless of key order. Used to refuse re-dispatching a call that
// already FAILED this goal.
function callSignature(step: ActionStep): string {
  const { tool, args: callArgs } = driverCallForStep(step);
  const keys = Object.keys(callArgs).sort();
  return `${tool}:${keys.map((key) => `${key}=${JSON.stringify(callArgs[key])}`).join("&")}`;
}

// The clean SurfaceSnapshot fields of a CuaWindow (dropping focused/bounds/
// zIndex), so a window resolved by pointing carries the exact surface shape the
// audit trail + candidate list expect.
function cuaWindowSurface(window: CuaWindow): SurfaceSnapshot {
  return {
    id: window.id,
    title: window.title,
    app: window.app,
    ...(window.pid !== undefined ? { pid: window.pid } : {}),
    ...(window.windowId !== undefined ? { windowId: window.windowId } : {}),
    availability: window.availability,
    accessStatus: window.accessStatus,
  };
}

// Map the live CUA windows (real geometry + stacking order from list_windows)
// into the binder's AttentionWindow shape — the real pointable layout the
// temporal binder ranks a head/hand point against, so a deictic ("here") binds
// to the frontmost WINDOW under the point instead of a whole display. A window
// the driver couldn't measure (no bounds) can't be hit-tested, so it is dropped.
// ponytail: coordinate space — bounds + the head/hand cursor must share the
// global virtual-desktop px space; a Retina points-vs-pixels scale mismatch is a
// calibration knob to tune in manual testing, not a logic change here.
function driverWindowsToPointable(windows: readonly CuaWindow[]): readonly AttentionWindow[] {
  return windows
    .filter(
      (window): window is CuaWindow & { bounds: NonNullable<CuaWindow["bounds"]> } =>
        window.bounds !== undefined,
    )
    .map((window) => ({
      surface: cuaWindowSurface(window),
      bounds: window.bounds,
      ...(window.zIndex !== undefined ? { zIndex: window.zIndex } : {}),
    }));
}

function blockedIntent(
  input: IntentInput,
  id: string,
  createdAt: string,
  reason: string,
): ResolvedIntent {
  return {
    status: "blocked",
    id,
    input,
    constraints: [],
    requires_approval: false,
    target_agent: "none",
    reason,
    createdAt,
  };
}

type GoalRunState = {
  sessionId: string;
  baseInput: IntentInput;
  observations: readonly GoalLoopObservation[];
  // Index of the next loop turn. Distinct from the budget: a turn that only
  // perceives + clarifies costs no budget; only executed actions do.
  nextTick: number;
  // Tool calls executed so far against this goal, checked against the budget.
  toolCalls: number;
  toolCallBudget: number;
  referent: SelectedReferent | null;
  // (tool,args) signatures that already FAILED this goal (KD2 recovery floor).
  // The resolver sometimes re-issues an identical failing call; the loop refuses
  // to dispatch any signature in here again, so a dead action can't run away to
  // the budget. Successful calls are never recorded, so legitimate repeats (a
  // second scroll) still flow.
  failedSignatures: ReadonlySet<string>;
};

export function useVoiceCuaController(args: {
  driver: CuaDriver;
  headPointing?: HeadPointingSnapshot;
  now?: () => string;
  // The loop's "head": emits the next driver tool call toward the goal. Defaults
  // to the full-surface LLM resolver; tests inject a fake. (Named resolveIntent
  // for back-compat with existing callers/tests.)
  resolveIntent?: NextToolCallResolver;
  targetResolveDelayMs?: number;
  // The live pointing signals read once at intent time, gathered behind a single
  // getter: the locked gesture referent (#35), the live gesture cursor, the most
  // recent CLOSED capture trace (U5 — head + hand + word streams on one epoch-ms
  // clock; null on a non-capture utterance), and the pointable-window layout the
  // temporal binder (U6/U7) ranks against. All fields tolerate null/empty, in
  // which case the single end-of-speech snapshot stays the sole signal (fallback
  // preserved). See {@link PointingContext} and {@link buildPointingEvidence}.
  getPointingContext?: () => PointingContext;
  // Per-goal autonomous-loop ceiling on executed tool calls (default
  // DEFAULT_TOOL_CALL_BUDGET). The loop stops with a clear blocked reason at the
  // ceiling so a misfiring loop cannot run away.
  toolCallBudget?: number;
  // Local/test observability sink. Remote export stays deliberately out of this
  // hook; callers decide whether to pass a local, test, or remote-gated sink.
  observability?: ObservabilityOptions;
}) {
  const [intent, setIntent] = useState<ResolvedIntent | null>(null);
  const [runResult, setRunResult] = useState<PlanRunResult | null>(null);
  const [session, setSession] = useState<SupervisionSession | null>(null);
  const [auditEvents, setAuditEvents] = useState<readonly SupervisionAuditEvent[]>([]);
  const audit = useRef(createActionAuditStore());
  const sessions = useRef(createSupervisionSessionStore());
  const goalRun = useRef<GoalRunState | null>(null);
  // Set when the user interrupts (pause/stop): the loop checks this at every
  // await boundary and stops cleanly, clearing any pending-approval state.
  const interrupted = useRef(false);
  const headPointingRef = useRef(args.headPointing);
  const resolveIntentRef = useRef<NextToolCallResolver>(args.resolveIntent ?? resolveNextToolCall);
  // The driver's self-described tool catalog (U1), built once per controller and
  // handed to the resolver as the model's callable-tool menu. A failed load is
  // not cached, so a transient driver error retries next turn.
  const catalog = useRef(createToolCatalog(args.driver));
  headPointingRef.current = args.headPointing;
  resolveIntentRef.current = args.resolveIntent ?? resolveNextToolCall;
  const timestamp = () => args.now?.() ?? new Date().toISOString();

  function observabilityBase(sessionId: string, event: string, at: string) {
    return {
      timestamp: at,
      component: OBSERVABILITY_COMPONENT,
      event,
      sessionId,
      correlationId: sessionId,
      traceId: `trace-${sessionId}`,
      ...(args.observability?.release ? { release: args.observability.release } : {}),
      ...(args.observability?.platform ? { platform: args.observability.platform } : {}),
    };
  }

  function emitObservability(record: ObservabilityRecord) {
    const parsed = safeParseObservabilityRecord(record);
    if (!parsed.success) {
      console.warn("[handsoff.observability] dropped invalid record", {
        component: record.component,
        event: record.event,
        reason: parsed.error.issues.map((issue) => issue.message).join("; "),
      });
      return;
    }
    (args.observability?.sink ?? defaultObservabilitySink).emit(parsed.data);
  }

  function emitLog(
    sessionId: string,
    event: string,
    at: string,
    level: Extract<ObservabilityRecord, { kind: "log" }>["level"],
    attributes: ObservabilityAttributes = {},
  ) {
    emitObservability({
      ...observabilityBase(sessionId, event, at),
      kind: "log",
      level,
      attributes,
    });
  }

  function emitSpan(
    sessionId: string,
    event: string,
    startedAt: string,
    finishedAt: string,
    spanId: string,
    status: Extract<ObservabilityRecord, { kind: "span" }>["status"],
    attributes: ObservabilityAttributes = {},
  ) {
    emitObservability({
      ...observabilityBase(sessionId, event, finishedAt),
      kind: "span",
      spanId,
      durationMs: elapsedMs(startedAt, finishedAt),
      status,
      attributes,
    });
  }

  function emitMetric(
    sessionId: string,
    event: string,
    at: string,
    name: string,
    value: number,
    unit?: string,
    attributes: ObservabilityAttributes = {},
  ) {
    emitObservability({
      ...observabilityBase(sessionId, event, at),
      kind: "metric",
      name,
      value,
      ...(unit ? { unit } : {}),
      attributes,
    });
  }

  function emitAnalytics(
    sessionId: string,
    event: string,
    at: string,
    stage: Extract<ObservabilityRecord, { kind: "analytics" }>["stage"],
    attributes: ObservabilityAttributes = {},
  ) {
    if (!args.observability?.analyticsConsent) return;
    emitObservability({
      ...observabilityBase(sessionId, event, at),
      kind: "analytics",
      stage,
      attributes,
    });
  }

  function emitError(
    sessionId: string,
    event: string,
    at: string,
    errorClass: string,
    handled: boolean,
    attributes: ObservabilityAttributes = {},
  ) {
    emitObservability({
      ...observabilityBase(sessionId, event, at),
      kind: "error",
      errorClass,
      handled,
      attributes,
    });
  }

  // Cursor fallback: probe the active window via the CUA driver, degrading the
  // surface to "unknown" availability/access when the probe doesn't succeed.
  async function resolveActiveWindowSurface(): Promise<SurfaceSnapshot> {
    const resolved = await args.driver.getWindowState({ surface: ACTIVE_WINDOW_SURFACE });
    return resolved.status === "succeeded"
      ? resolved.value.surface
      : {
          ...ACTIVE_WINDOW_SURFACE,
          availability: "unknown" as const,
          accessStatus: "unknown" as const,
        };
  }

  // Gather the live pointing signals once (gesture lock, gesture cursor, the
  // just-closed capture trace, the pointable-window layout) for the pure fusion
  // builder. Defaults every field so a missing getter degrades to the snapshot
  // fallback rather than throwing.
  function pointingContext(): PointingContext {
    const context = args.getPointingContext?.();
    return {
      gestureEvidence: context?.gestureEvidence ?? null,
      gestureCursor: context?.gestureCursor ?? null,
      captureTrace: context?.captureTrace ?? null,
      pointableWindows: context?.pointableWindows ?? [],
    };
  }

  // The live CUA window layout (real geometry + z-order) for the temporal
  // binder. Returns [] when the driver is unavailable, so the caller falls back
  // to the camera display layout the gesture lane publishes.
  async function pointableWindowsFromDriver(): Promise<readonly AttentionWindow[]> {
    const result = await args.driver.listWindows();
    return result.status === "succeeded" ? driverWindowsToPointable(result.value) : [];
  }

  async function createIntent(finalTranscript: FinalTranscript) {
    interrupted.current = false;
    await wait(args.targetResolveDelayMs ?? DEFAULT_TARGET_RESOLVE_DELAY_MS);
    const createdAt = timestamp();
    const started = sessions.current.start(createdAt);
    emitLog(started.id, "session_started", createdAt, "info", {
      confidence: finalTranscript.confidence,
      speech_chars: finalTranscript.text.length,
    });
    emitMetric(
      started.id,
      "stt_latency_recorded",
      createdAt,
      "stt.latency.ms",
      finalTranscript.latencyMs,
      "ms",
    );
    emitAnalytics(started.id, "session_started", createdAt, "session_started");
    emitAnalytics(started.id, "transcript_accepted", createdAt, "transcript_accepted", {
      confidence: finalTranscript.confidence,
      speech_chars: finalTranscript.text.length,
      stt_latency_ms: finalTranscript.latencyMs,
    });

    // Fuse every available pointing signal into the evidence list + deduplicated
    // surface candidates (combinative, U7 multi-target binding included). Pure
    // builder — the active-window fallback is the only async step, run only when
    // no gesture/head/bound evidence exists.
    // Prefer the live CUA window layout (real geometry + z-order) so the temporal
    // binder resolves a deictic to the frontmost WINDOW under the point, not the
    // display placeholder. The binder is the only consumer of pointableWindows and
    // only runs when there's a capture trace to align words against, so a
    // non-capture utterance skips the extra driver round-trip; fall back to the
    // camera display layout when the driver returns nothing.
    const baseContext = pointingContext();
    const driverWindows = baseContext.captureTrace ? await pointableWindowsFromDriver() : [];
    const context: PointingContext = {
      ...baseContext,
      pointableWindows: driverWindows.length > 0 ? driverWindows : baseContext.pointableWindows,
    };
    const { pointingEvidence, surfaceCandidates } = await buildPointingEvidence(
      finalTranscript,
      context,
      headPointingRef.current,
      resolveActiveWindowSurface,
    );
    emitAnalytics(started.id, "context_selected", timestamp(), "context_selected", {
      evidence_count: pointingEvidence.length,
      surface_count: surfaceCandidates.length,
      has_capture_trace: context.captureTrace !== null,
      has_gesture: context.gestureEvidence !== null || context.gestureCursor !== null,
      has_head: headPointingRef.current !== undefined,
    });

    const input: IntentInput = {
      sessionId: started.id,
      speech: { finalTranscript },
      pointingEvidence: [...pointingEvidence],
      surfaceCandidates: [...surfaceCandidates],
    };
    const run: GoalRunState = {
      sessionId: started.id,
      baseInput: input,
      observations: [],
      nextTick: 0,
      toolCalls: 0,
      toolCallBudget: args.toolCallBudget ?? DEFAULT_TOOL_CALL_BUDGET,
      referent: null,
      failedSignatures: new Set(),
    };
    goalRun.current = run;
    setSession(started);
    await continueGoal(run, createdAt);
  }

  async function observeGoalTick(
    tick: number,
    previousAction?: GoalLoopObservation["previousAction"],
  ): Promise<GoalLoopObservation> {
    const capturedAt = timestamp();
    const windowsResult = await args.driver.listWindows();
    const windows = windowsResult.status === "succeeded" ? [...windowsResult.value] : [];
    const focused = windows.find((window) => window.focused) ?? windows[0];
    const stateResult = focused
      ? await args.driver.getWindowState({ surface: focused })
      : ({
          status: "blocked",
          reason: "No windows available to observe",
        } satisfies CuaActionResult);
    return {
      tick,
      capturedAt,
      windows,
      ...(stateResult.status === "succeeded" ? { state: stateResult.value } : {}),
      ...(previousAction ? { previousAction } : {}),
    };
  }

  function inputForTick(
    run: GoalRunState,
    tick: number,
    observations: readonly GoalLoopObservation[],
  ): IntentInput {
    if (tick === 0) {
      return {
        ...run.baseInput,
        goalSession: {
          goal: run.baseInput.speech.finalTranscript.text,
          tick,
          observations: [...observations],
        },
      };
    }

    const latest = observations.at(-1);
    const surface = latest?.state?.surface ?? latest?.windows[0];
    return {
      ...run.baseInput,
      pointingEvidence: surface
        ? [
            {
              source: "active_window",
              confidence: 1,
              strategy: "goal-loop-live-observation",
              surface,
            },
          ]
        : run.baseInput.pointingEvidence,
      surfaceCandidates: latest?.windows.length ? latest.windows : run.baseInput.surfaceCandidates,
      goalSession: {
        goal: run.baseInput.speech.finalTranscript.text,
        tick,
        observations: [...observations],
      },
    };
  }

  function recordIntent(sessionId: string, createdAt: string, next: ResolvedIntent) {
    audit.current.record({
      kind: "intent_created",
      sessionId,
      actionId: next.status === "ready" ? next.action_plan.id : next.id,
      recordedAt: createdAt,
      intent: next,
    });
    setAuditEvents(audit.current.forSession(sessionId));
  }

  // Per-call Intention Log record (U3 / KD6): every executed tool call, with the
  // transcript that drove it, the bound referent, the derived risk + approval
  // state, and the typed result — the replayable provenance the supervision
  // surface shows. One record per step in the executed one-action tick.
  function recordToolCalls(
    run: GoalRunState,
    readyIntent: Extract<ResolvedIntent, { status: "ready" }>,
    observation: GoalLoopObservation | undefined,
    approval: "auto" | "approved" | "rejected",
    result: CuaActionResult,
    recordedAt: string,
  ) {
    for (const step of readyIntent.action_plan.action_plan) {
      const tool = driverToolForStep(step);
      const target = toolCallTargetForStep(step, observation);
      audit.current.record({
        kind: "tool_call",
        sessionId: run.sessionId,
        actionId: readyIntent.action_plan.id,
        recordedAt,
        transcript: run.baseInput.speech.finalTranscript.text,
        referent: readyIntent.referent ?? run.referent,
        tool,
        ...(target ? { target } : {}),
        risk: riskForToolName(toolNameForStep(step), target),
        approval,
        result,
      });
    }
    setAuditEvents(audit.current.forSession(run.sessionId));
  }

  function finishGoal(run: GoalRunState, status: TerminalSessionStatus, finishedAt: string) {
    const nextSession = sessions.current.finish(run.sessionId, status, finishedAt);
    setSession(nextSession);
    goalRun.current = null;
  }

  // Stop the loop cleanly when the user has interrupted. Returns true when the
  // caller should bail. Records the blocked intent + finishes the session only
  // once — if the synchronous interrupt() already tore down the run, the caller
  // still bails but does not double-record.
  function stopIfInterrupted(run: GoalRunState, input: IntentInput, at: string): boolean {
    if (!interrupted.current) return false;
    if (goalRun.current === null) return true;
    const next = blockedIntent(input, `intent-interrupted-${run.nextTick}`, at, "Interrupted");
    setIntent(next);
    setRunResult(null);
    recordIntent(run.sessionId, at, next);
    finishGoal(run, "blocked", at);
    return true;
  }

  async function continueGoal(
    run: GoalRunState,
    createdAt: string,
    previousAction?: GoalLoopObservation["previousAction"],
  ) {
    if (stopIfInterrupted(run, inputForTick(run, run.nextTick, run.observations), createdAt)) {
      return;
    }
    if (run.toolCalls >= run.toolCallBudget) {
      const input = inputForTick(run, run.nextTick, run.observations);
      const next = blockedIntent(
        input,
        `intent-budget-${run.nextTick}`,
        createdAt,
        `Goal loop reached the action budget of ${run.toolCallBudget}`,
      );
      setIntent(next);
      setRunResult(null);
      recordIntent(run.sessionId, createdAt, next);
      finishGoal(run, "blocked", createdAt);
      return;
    }

    const observation = await observeGoalTick(run.nextTick, previousAction);
    const observations = [...run.observations, observation];
    const input = inputForTick(run, run.nextTick, observations);
    if (stopIfInterrupted(run, input, timestamp())) return;
    emitLog(run.sessionId, "intent_input_prepared", timestamp(), "debug", {
      evidence_count: input.pointingEvidence.length,
      surface_count: input.surfaceCandidates.length,
      tick: run.nextTick,
      tool_calls: run.toolCalls,
    });
    const toolsResult = await catalog.current.load();
    const tools: readonly DriverToolDefinition[] =
      toolsResult.status === "succeeded" ? toolsResult.value : [];
    const resolveStartedAt = timestamp();
    const resolved = await resolveIntentRef.current(input, { createdAt, tools });
    const resolvedAt = timestamp();
    if (stopIfInterrupted(run, input, timestamp())) return;
    // The gate (U2/KD3) derives risk per call from the actual tool each step
    // reaches — escalating a commit click and never trusting a model downgrade.
    // Reflect that effective risk on the displayed ready intent so the approval
    // surface and the loop's pause decision agree (a model-declared reversible
    // click on "Send" still shows Approve/Reject).
    const next =
      resolved.status === "ready"
        ? withEffectiveRisk(resolved, planToolRisk(resolved.action_plan, observation))
        : resolved;
    emitSpan(
      run.sessionId,
      "intent_resolved",
      resolveStartedAt,
      resolvedAt,
      `intent-resolve-${run.nextTick}`,
      "ok",
      {
        status: next.status,
        surface_count: input.surfaceCandidates.length,
        tick: run.nextTick,
        tool_count: tools.length,
      },
    );
    emitMetric(
      run.sessionId,
      "command_to_plan_latency_recorded",
      resolvedAt,
      "command_to_plan.ms",
      elapsedMs(resolveStartedAt, resolvedAt),
      "ms",
      { status: next.status, tick: run.nextTick },
    );
    emitLog(run.sessionId, "intent_resolved", resolvedAt, "info", {
      status: next.status,
      plan_steps: "action_plan" in next ? next.action_plan.action_plan.length : 0,
      tick: run.nextTick,
    });
    if (next.status === "ready" && next.referent) {
      emitMetric(
        run.sessionId,
        "referent_success_recorded",
        resolvedAt,
        "referent.success.count",
        1,
        "count",
        { referent_source: next.referent.source },
      );
    }
    if (
      (next.status === "blocked" || next.status === "clarification_required") &&
      run.nextTick === 0 &&
      run.toolCalls === 0
    ) {
      emitMetric(
        run.sessionId,
        "false_activation_recorded",
        resolvedAt,
        "false_activation.count",
        1,
        "count",
        { status: next.status },
      );
    }
    setIntent(next);
    if (next.status !== "satisfied") setRunResult(null);
    recordIntent(run.sessionId, createdAt, next);

    if (next.status === "satisfied") {
      finishGoal(run, "succeeded", createdAt);
      return;
    }
    if (next.status !== "ready") {
      finishGoal(run, "blocked", createdAt);
      return;
    }

    // Carry the referent the resolver bound this tick into the run so later
    // ticks (and the per-call audit) keep the deictic provenance.
    const nextRun: GoalRunState = {
      ...run,
      observations,
      nextTick: run.nextTick + 1,
      referent: next.referent ?? run.referent,
    };
    goalRun.current = nextRun;

    // Read-only / reversible auto-run; mutating / destructive pause for
    // approval. The pause is held by returning here with the ready intent set —
    // approve() resumes by running the same tick, reject() ends it.
    if (riskLevelRequiresApproval(next.risk_level)) return;

    await runGoalAction(nextRun, next, observation);
  }

  async function runGoalAction(
    run: GoalRunState,
    readyIntent: Extract<ResolvedIntent, { status: "ready" }>,
    observation: GoalLoopObservation | undefined,
    approval?: ReturnType<typeof makeApprovalDecision>,
  ) {
    if (stopIfInterrupted(run, readyIntent.input, timestamp())) return;
    const runningAt = timestamp();
    const approvalState: "auto" | "approved" | "rejected" = approval ? "approved" : "auto";

    // Loop-dedup guard (KD2 recovery floor): the resolver sometimes re-issues a
    // call that already failed this goal (e.g. launch_app on an app that doesn't
    // exist). Refuse to dispatch a (tool,args) we've already seen fail — stop
    // with a clear blocked reason instead of looping the dead action to the
    // budget. Only verbatim-failed signatures are blocked, so a genuine
    // alternative the resolver tries still runs.
    const repeated = readyIntent.action_plan.action_plan.find((step) =>
      run.failedSignatures.has(callSignature(step)),
    );
    if (repeated) {
      const result: CuaActionResult = {
        status: "blocked",
        reason: `Stopped: the resolver kept retrying a call that already failed (${toolNameForStep(repeated)}).`,
      };
      setSession(sessions.current.run(run.sessionId, runningAt));
      recordToolCalls(run, readyIntent, observation, approvalState, result, runningAt);
      emitActionOutcome(run.sessionId, readyIntent, runningAt, runningAt, result, approvalState);
      setRunResult({ status: "blocked", result });
      finishGoal(run, "blocked", runningAt);
      return;
    }

    // Per-call gate (U2): ask gateToolCall for EVERY step before dispatch,
    // deriving the gate from the real tool + target, never the model's claim. A
    // commit step with no matching approval blocks the whole tick here — the
    // typed dispatch never runs.
    const blocked = firstBlockedStep(readyIntent.action_plan.action_plan, observation, !!approval);
    if (blocked) {
      setSession(sessions.current.run(run.sessionId, runningAt));
      recordToolCalls(run, readyIntent, observation, approvalState, blocked, runningAt);
      emitActionOutcome(run.sessionId, readyIntent, runningAt, runningAt, blocked, approvalState);
      const result: PlanRunResult = { status: "blocked", result: blocked };
      setRunResult(result);
      finishGoal(run, "blocked", runningAt);
      return;
    }

    setSession(sessions.current.run(run.sessionId, runningAt));
    setRunResult({ status: "running" });
    // The gate above is the source of truth for *whether* to run. Dispatch every
    // step through the GENERIC driver passthrough (`driver.call`, U1) — the loop
    // is no longer bound to the typed 6-kind executor, so the full 36-tool
    // surface (scroll/hotkey/drag/right_click/…) is reachable. Stop at the first
    // failure and feed it forward for recovery.
    const { result: actionResult, failedSignature } = await dispatchPlan(
      readyIntent.action_plan.action_plan,
    );
    const actionFinishedAt = timestamp();
    const status: PlanRunResult["status"] =
      actionResult.status === "succeeded" ? "succeeded" : actionResult.status;
    const result: PlanRunResult = { status, result: actionResult };
    recordToolCalls(run, readyIntent, observation, approvalState, actionResult, runningAt);
    emitActionOutcome(
      run.sessionId,
      readyIntent,
      runningAt,
      actionFinishedAt,
      actionResult,
      approvalState,
    );
    setRunResult(result);
    setAuditEvents(audit.current.forSession(run.sessionId));

    const ranRun: GoalRunState = {
      ...run,
      toolCalls: run.toolCalls + readyIntent.action_plan.action_plan.length,
      // Remember a failed (tool,args) so the dedup guard above won't re-dispatch
      // it next turn — the loop's floor against a runaway repeat.
      failedSignatures: failedSignature
        ? new Set([...run.failedSignatures, failedSignature])
        : run.failedSignatures,
    };
    goalRun.current = ranRun;

    if (stopIfInterrupted(ranRun, readyIntent.input, timestamp())) return;

    // Recovery (KD2): a failed action is a normal observation, not the end of
    // the goal. Feed the failure forward so the resolver tries an alternative;
    // only an exhausted budget / interrupt / a resolver-emitted blocked|done
    // ends the loop.
    await continueGoal(ranRun, timestamp(), {
      actionId: readyIntent.action_plan.id,
      result: actionResult,
    });
  }

  function emitActionOutcome(
    sessionId: string,
    readyIntent: Extract<ResolvedIntent, { status: "ready" }>,
    startedAt: string,
    finishedAt: string,
    result: CuaActionResult,
    approval: "auto" | "approved" | "rejected",
  ) {
    const succeeded = result.status === "succeeded";
    const attributes = {
      approval,
      plan_steps: readyIntent.action_plan.action_plan.length,
      risk: readyIntent.risk_level,
      status: result.status,
    };
    emitSpan(
      sessionId,
      "cua_action_finished",
      startedAt,
      finishedAt,
      `cua-action-${readyIntent.action_plan.id}`,
      succeeded ? "ok" : "error",
      attributes,
    );
    emitMetric(
      sessionId,
      "cua_action_latency_recorded",
      finishedAt,
      "cua.action.latency.ms",
      elapsedMs(startedAt, finishedAt),
      "ms",
      { status: result.status },
    );
    emitAnalytics(
      sessionId,
      succeeded ? "action_completed" : "action_failed",
      finishedAt,
      succeeded ? "action_completed" : "action_failed",
      attributes,
    );
    if (succeeded) return;
    const errorClass = actionErrorClass(result);
    emitMetric(sessionId, "cua_failure_recorded", finishedAt, "cua.failure.count", 1, "count", {
      error_class: errorClass,
      status: result.status,
    });
    emitLog(sessionId, "cua_action_failed", finishedAt, "warn", {
      error_class: errorClass,
      status: result.status,
    });
    emitError(sessionId, "cua_action_failed", finishedAt, errorClass, true, {
      status: result.status,
    });
  }

  // Execute a tick's steps in order through `driver.call`, normalizing each
  // driver result to a CuaActionResult. Stops at the first non-success so a
  // failed step is surfaced for recovery; the last step's result represents the
  // tick. The fallback summary names the tool that ran.
  async function dispatchPlan(
    steps: readonly ActionStep[],
  ): Promise<{ result: CuaActionResult; failedSignature: string | null }> {
    let last: CuaActionResult = { status: "succeeded", summary: "No action" };
    for (const step of steps) {
      const { tool, args: callArgs } = driverCallForStep(step);
      const callResult = await args.driver.call(tool, callArgs);
      last = cuaResultToActionResult(callResult, `Called ${tool}`);
      if (last.status !== "succeeded")
        return { result: last, failedSignature: callSignature(step) };
    }
    return { result: last, failedSignature: null };
  }

  async function approve() {
    const run = goalRun.current;
    if (intent?.status !== "ready" || !session || !run) return;
    const runningAt = timestamp();
    emitAnalytics(session.id, "plan_approved", runningAt, "plan_approved", {
      plan_steps: intent.action_plan.action_plan.length,
      risk: intent.risk_level,
    });
    await runGoalAction(
      run,
      intent,
      run.observations.at(-1),
      makeApprovalDecision(intent.action_plan.id, "approved", runningAt),
    );
  }

  async function reject() {
    const run = goalRun.current;
    if (intent?.status !== "ready" || !session) return;
    const decidedAt = timestamp();
    // Rejection runs NOTHING: no tool call is dispatched. Record the rejected
    // call(s) for the audit trail and end the session rejected.
    const rejected: CuaActionResult = {
      status: "blocked",
      reason: "Rejected before execution",
    };
    if (run) {
      recordToolCalls(run, intent, run.observations.at(-1), "rejected", rejected, decidedAt);
    }
    emitAnalytics(session.id, "plan_rejected", decidedAt, "plan_rejected", {
      plan_steps: intent.action_plan.action_plan.length,
      risk: intent.risk_level,
    });
    audit.current.record({
      kind: "execution_finished",
      sessionId: session.id,
      actionId: intent.action_plan.id,
      recordedAt: decidedAt,
      status: "rejected",
    });
    setSession(sessions.current.finish(session.id, "rejected", decidedAt));
    goalRun.current = null;
    setRunResult({ status: "rejected" });
    setAuditEvents(audit.current.forSession(session.id));
  }

  // Always-available interrupt (KD6): cancel the in-flight loop, clear the
  // pending-approval state, and finish the session blocked. The loop checks the
  // flag at every await boundary; an interrupt with nothing pending just arms
  // the flag so an in-flight tick stops on its next boundary.
  function interrupt() {
    interrupted.current = true;
    const run = goalRun.current;
    if (!run) return;
    if (session && session.status !== "succeeded" && session.status !== "blocked") {
      const at = timestamp();
      const input = inputForTick(run, run.nextTick, run.observations);
      const next = blockedIntent(input, `intent-interrupted-${run.nextTick}`, at, "Interrupted");
      emitAnalytics(run.sessionId, "interrupt_used", at, "interrupt_used", {
        tick: run.nextTick,
        tool_calls: run.toolCalls,
      });
      setIntent(next);
      setRunResult(null);
      recordIntent(run.sessionId, at, next);
      finishGoal(run, "blocked", at);
    }
  }

  return {
    intent,
    runResult,
    session,
    auditEvents,
    approve,
    reject,
    interrupt,
    handleFinalTranscript: (finalTranscript: FinalTranscript) => void createIntent(finalTranscript),
  };
}
