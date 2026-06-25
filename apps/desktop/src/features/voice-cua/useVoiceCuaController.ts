import {
  gateToolCall,
  runApprovedPlan,
  type CuaActionPort,
  type PlanRunResult,
} from "@handsoff/actions";
import {
  riskForToolCall,
  riskLevelRequiresApproval,
  type ActionStep,
  type CuaActionResult,
  type CuaActionRequest,
  type DriverTool,
  type FinalTranscript,
  type GoalLoopObservation,
  type IntentInput,
  type PointingEvidence,
  type ResolvedIntent,
  type RiskLevel,
  type SelectedReferent,
  type SupervisionAuditEvent,
  type SurfaceSnapshot,
  type ToolCallTarget,
} from "@handsoff/contracts";
import { cuaResultToActionResult, type CuaDriver } from "@handsoff/cua";
import { resolveIntent, type ResolveIntentOptions } from "@handsoff/intent";
import {
  createActionAuditStore,
  createSupervisionSessionStore,
  type SupervisionSession,
  type TerminalSessionStatus,
} from "@handsoff/supervision";
import { useRef, useState } from "react";

import { makeApprovalDecision } from "../plan-preview/usePlanApproval";
import type { HeadPointingSnapshot } from "../head-pointing/useHeadPointing";

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

function wait(ms: number): Promise<void> {
  return ms > 0 ? new Promise((resolve) => setTimeout(resolve, ms)) : Promise.resolve();
}

function actionPortFor(driver: CuaDriver): CuaActionPort {
  return {
    launchApp: ({ appName, bundleId }: Extract<CuaActionRequest, { kind: "launch_app" }>) =>
      driver.launchApp({ appName, bundleId }),
    getWindowState: ({ target }: Extract<CuaActionRequest, { kind: "get_window_state" }>) =>
      driver
        .getWindowState(target)
        .then((result) =>
          cuaResultToActionResult(result, "Window state captured", (state) => state),
        ),
    click: ({ target }: Extract<CuaActionRequest, { kind: "click" }>) => driver.click(target),
    typeText: ({ target, text }: Extract<CuaActionRequest, { kind: "type_text" }>) =>
      driver.typeText(target, text),
    setValue: ({ target, value }: Extract<CuaActionRequest, { kind: "set_value" }>) =>
      driver.setValue(target, value),
    screenshot: ({ target }: Extract<CuaActionRequest, { kind: "screenshot" }>) =>
      driver
        .screenshot(target)
        .then((result) => cuaResultToActionResult(result, "Screenshot captured")),
  };
}

function terminal(status: PlanRunResult["status"]): TerminalSessionStatus {
  if (status === "queued" || status === "running") {
    throw new Error(`Cannot finish session with non-terminal status: ${status}`);
  }
  return status;
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

function actionResultFor(result: PlanRunResult, fallbackSummary: string): CuaActionResult {
  if (result.result) return result.result;
  if (result.status === "succeeded") return { status: "succeeded", summary: fallbackSummary };
  if (result.status === "blocked") return { status: "blocked", reason: fallbackSummary };
  return { status: "failed", error: fallbackSummary };
}

// The driver tool each typed ActionStep dispatches as. Used to key per-call risk
// (U2) off the real tool name the step will reach through the driver, so the
// loop gates on the same vocabulary the full-surface passthrough (U1) exposes.
function driverToolForStep(step: ActionStep): DriverTool {
  switch (step.kind) {
    case "click_element":
      return "click";
    case "type_text":
      return "type_text";
    case "set_value":
      return "set_value";
    case "launch_app":
      return "launch_app";
    // inspect_window_state / capture_screenshot are read-only perception.
    default:
      return "get_window_state";
  }
}

// Build the risk-relevant target for a click step from the latest observation:
// look the element up by index in the perceived AX elements so `riskForToolCall`
// can escalate a *commit* click (Send/Delete/…) to mutating while leaving plain
// navigation clicks free. Absent element metadata leaves the gate to its safe
// default (a click it cannot prove is navigation stays gated).
function toolCallTargetForStep(
  step: ActionStep,
  observation: GoalLoopObservation | undefined,
): ToolCallTarget | undefined {
  if (step.kind !== "click_element") return undefined;
  const index = step.target.elementIndex;
  if (index === undefined) return undefined;
  const element = observation?.state?.elements.find((candidate) => candidate.index === index);
  if (!element) return undefined;
  return {
    element: {
      ...(element.role !== undefined && { role: element.role }),
      ...(element.label !== undefined && { title: element.label, label: element.label }),
      ...(element.value !== undefined && { value: element.value }),
    },
  };
}

// The effective risk of a whole one-action-per-tick plan. Risk is the MAX over:
//   - each step's tool-derived risk (U2 `riskForToolCall`, with click element
//     semantics escalating a commit click — Send/Delete/… — to mutating), and
//   - the plan's declared `risk_level`.
// Taking the max means the gate can ESCALATE but the model can never DOWNGRADE
// below what its own tool risk implies (KD3's anti-bypass rule): a model that
// labels a Send click read_only is still gated, while a model that knows a step
// is mutating keeps it gated even when the element label looks benign. The
// per-step max also gates a tick that mixes a free launch with a commit click.
function planToolRisk(
  plan: Extract<ResolvedIntent, { status: "ready" }>["action_plan"],
  observation: GoalLoopObservation | undefined,
): RiskLevel {
  return plan.action_plan.reduce<RiskLevel>((max, step) => {
    const risk = riskForToolCall(driverToolForStep(step), toolCallTargetForStep(step, observation));
    return maxRisk(max, risk);
  }, plan.risk_level);
}

const RISK_RANK: Record<RiskLevel, number> = {
  read_only: 0,
  reversible: 1,
  mutating: 2,
  destructive_external: 3,
};

function maxRisk(a: RiskLevel, b: RiskLevel): RiskLevel {
  return RISK_RANK[b] > RISK_RANK[a] ? b : a;
}

// Stamp the gate's effective (possibly escalated) risk onto the ready intent so
// the displayed plan + the approval surface agree with the loop's pause: a
// model-declared reversible click on a commit control becomes a mutating plan
// that visibly requires approval. Immutable — returns a new intent.
function withEffectiveRisk(
  intent: Extract<ResolvedIntent, { status: "ready" }>,
  risk: RiskLevel,
): Extract<ResolvedIntent, { status: "ready" }> {
  if (risk === intent.risk_level) return intent;
  const requires = riskLevelRequiresApproval(risk);
  return {
    ...intent,
    risk_level: risk,
    requires_approval: requires,
    action_plan: {
      ...intent.action_plan,
      risk_level: risk,
      requires_approval: requires,
    },
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
};

export type IntentResolveInvoke = <T>(
  command: string,
  args?: Record<string, unknown>,
) => Promise<T>;

export function createIntentWorkerResolver(invoke: IntentResolveInvoke) {
  return (input: IntentInput, options: ResolveIntentOptions): Promise<ResolvedIntent> => {
    const client: NonNullable<ResolveIntentOptions["client"]> = {
      chat: {
        completions: {
          async parse(request) {
            const { model, messages } = request as { model?: unknown; messages?: unknown };
            return invoke("intent_resolve", { request: { model, messages } });
          },
        },
      },
    };
    return resolveIntent(input, { ...options, client });
  };
}

export function useVoiceCuaController(args: {
  driver: CuaDriver;
  headPointing?: HeadPointingSnapshot;
  now?: () => string;
  resolveIntent?: (input: IntentInput, options: ResolveIntentOptions) => Promise<ResolvedIntent>;
  targetResolveDelayMs?: number;
  // The live gesture referent (#35): when the camera has a locked point at intent
  // time it returns gesture `PointingEvidence`; null when nothing is locked.
  getGestureEvidence?: () => PointingEvidence | null;
  // The live gesture cursor position (even without a locked referent). Provided per-frame
  // by the CameraPanel and combined with head/face evidence in intent fusion.
  getGestureCursor?: () => { x: number; y: number } | null;
  // Per-goal autonomous-loop ceiling on executed tool calls (default
  // DEFAULT_TOOL_CALL_BUDGET). The loop stops with a clear blocked reason at the
  // ceiling so a misfiring loop cannot run away.
  toolCallBudget?: number;
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
  const resolveIntentRef = useRef(args.resolveIntent ?? resolveIntent);
  headPointingRef.current = args.headPointing;
  resolveIntentRef.current = args.resolveIntent ?? resolveIntent;
  const timestamp = () => args.now?.() ?? new Date().toISOString();

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

  async function createIntent(finalTranscript: FinalTranscript) {
    interrupted.current = false;
    await wait(args.targetResolveDelayMs ?? DEFAULT_TARGET_RESOLVE_DELAY_MS);
    const createdAt = timestamp();
    const started = sessions.current.start(createdAt);
    const gesture = args.getGestureEvidence?.() ?? null;
    const gestureCursor = args.getGestureCursor?.() ?? null;
    const headPointing = headPointingRef.current;
    const headCandidates = headPointing?.candidates ?? [];

    // Combinative pointing evidence: combine all available signals rather than
    // using a priority hierarchy. Gesture referent, gesture cursor position,
    // and face tracker evidence are all included when available.
    const pointingEvidence: PointingEvidence[] = [];

    // Locked referent from gesture (highest signal quality — has a specific surface).
    if (gesture) {
      pointingEvidence.push(gesture);
    }
    // Gesture cursor position (even without a locked referent). Added when no
    // locked gesture referent already carries a cursor.
    if (gestureCursor && (!gesture || !gesture.cursor)) {
      pointingEvidence.push({
        source: "gesture",
        confidence: gesture ? gesture.confidence : 0.3,
        strategy: "wrist-ray-position",
        cursor: gestureCursor,
      });
    }
    // Face tracker cursor + head attention candidates.
    if (headPointing && headPointing.point) {
      pointingEvidence.push({
        source: "head",
        confidence: 0.5,
        strategy: "face-tracker-position",
        cursor: headPointing.point,
      });
    }
    for (const candidate of headCandidates) {
      pointingEvidence.push({
        source: "head",
        confidence: candidate.score,
        strategy: "head-neighborhood",
        surface: candidate.surface,
        ...(headPointing?.point && { cursor: headPointing.point }),
      });
    }
    // When head is present but no candidates came in yet, include a low-confidence
    // head entry so the intent engine still sees the face tracker signal.
    if (headPointing && headCandidates.length === 0) {
      pointingEvidence.push({
        source: "head",
        confidence: 0,
        strategy: "head-neighborhood-empty",
        ...(headPointing.point && { cursor: headPointing.point }),
      });
    }
    // Fallback to active window only when no gesture or head evidence is available.
    if (pointingEvidence.length === 0) {
      pointingEvidence.push({
        source: "cursor",
        confidence: 1,
        strategy: "active-window-current-cursor",
        surface: await resolveActiveWindowSurface(),
      });
    }

    // Deduplicated surface candidates from all evidence.
    const seenIds = new Set<string>();
    const surfaceCandidates = pointingEvidence
      .map((e) => e.surface)
      .filter((s): s is NonNullable<typeof s> => {
        if (!s) return false;
        if (seenIds.has(s.id)) return false;
        seenIds.add(s.id);
        return true;
      });

    const input: IntentInput = {
      sessionId: started.id,
      speech: { finalTranscript },
      pointingEvidence,
      surfaceCandidates,
    };
    const run: GoalRunState = {
      sessionId: started.id,
      baseInput: input,
      observations: [],
      nextTick: 0,
      toolCalls: 0,
      toolCallBudget: args.toolCallBudget ?? DEFAULT_TOOL_CALL_BUDGET,
      referent: null,
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
        risk: riskForToolCall(tool, target),
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
    // Diagnostic: the exact transcript + live observation handed to the intent engine.
    console.info("[handsoff] intent input", {
      transcript: input.speech.finalTranscript.text,
      tick: input.goalSession?.tick,
      toolCalls: run.toolCalls,
      surfaceCandidates: input.surfaceCandidates.map((s) => ({
        id: s.id,
        app: s.app,
        title: s.title,
      })),
      pointingEvidence: input.pointingEvidence.map((p) => ({
        source: p.source,
        confidence: p.confidence,
        strategy: p.strategy,
        surfaceId: "surface" in p ? p.surface?.id : undefined,
      })),
    });
    const resolved = await resolveIntentRef.current(input, { resolver: "auto", createdAt });
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
    console.info("[handsoff] intent result", {
      status: next.status,
      reason: "reason" in next ? next.reason : undefined,
      summary: "summary" in next ? next.summary : undefined,
      referent: "referent" in next ? next.referent : undefined,
      planSteps:
        "action_plan" in next ? next.action_plan.action_plan.map((s) => s.kind) : undefined,
    });
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

    // Per-call gate (U2): ask gateToolCall for EVERY step before dispatch,
    // deriving the gate from the real tool + target, never the model's claim. A
    // commit step with no matching approval blocks the whole tick here — the
    // typed dispatch never runs.
    const blocked = firstBlockedStep(readyIntent.action_plan.action_plan, observation, !!approval);
    if (blocked) {
      setSession(sessions.current.run(run.sessionId, runningAt));
      recordToolCalls(run, readyIntent, observation, approvalState, blocked, runningAt);
      const result: PlanRunResult = { status: "blocked", result: blocked };
      setRunResult(result);
      finishGoal(run, "blocked", runningAt);
      return;
    }

    setSession(sessions.current.run(run.sessionId, runningAt));
    setRunResult({ status: "running" });
    // The gate above is the source of truth for *whether* to run; runApprovedPlan
    // does the typed dispatch + pre/post window capture. Hand it a matching
    // approval so its own plan-level risk check passes.
    const result = await runApprovedPlan({
      sessionId: run.sessionId,
      plan: readyIntent.action_plan,
      approval: makeApprovalDecision(readyIntent.action_plan.id, "approved", runningAt),
      cua: actionPortFor(args.driver),
      audit: audit.current,
      recordedAt: runningAt,
    });
    const actionResult = actionResultFor(result, readyIntent.action_plan.summary);
    recordToolCalls(run, readyIntent, observation, approvalState, actionResult, runningAt);
    setRunResult(result);
    setAuditEvents(audit.current.forSession(run.sessionId));

    const ranRun: GoalRunState = {
      ...run,
      toolCalls: run.toolCalls + readyIntent.action_plan.action_plan.length,
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

  async function approve() {
    const run = goalRun.current;
    if (intent?.status !== "ready" || !session || !run) return;
    const runningAt = timestamp();
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
    const result = await runApprovedPlan({
      sessionId: session.id,
      plan: intent.action_plan,
      approval: makeApprovalDecision(intent.action_plan.id, "rejected", decidedAt),
      cua: actionPortFor(args.driver),
      audit: audit.current,
      recordedAt: decidedAt,
    });
    if (run) {
      recordToolCalls(
        run,
        intent,
        run.observations.at(-1),
        "rejected",
        actionResultFor(result, intent.action_plan.summary),
        decidedAt,
      );
    }
    setSession(sessions.current.finish(session.id, terminal(result.status), decidedAt));
    goalRun.current = null;
    setRunResult(result);
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

// Run every step through the U2 per-call gate; return the first blocked result
// (the typed shape runApprovedPlan would record) if any step needs an approval
// it doesn't have, else null. This is where the autonomous loop actually wires
// gateToolCall: the gate is derived from the tool + target, never the model's
// claim, so a commit step (Send/Delete/…) blocks the tick when unapproved.
function firstBlockedStep(
  steps: readonly ActionStep[],
  observation: GoalLoopObservation | undefined,
  approved: boolean,
): Extract<CuaActionResult, { status: "blocked" }> | null {
  for (const step of steps) {
    const tool = driverToolForStep(step);
    const target = toolCallTargetForStep(step, observation);
    const gate = gateToolCall({ tool, ...(target ? { target } : {}), approved });
    if (!gate.allowed) return gate.result;
  }
  return null;
}
