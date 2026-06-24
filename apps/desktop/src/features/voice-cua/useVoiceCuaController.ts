import { runApprovedPlan, type CuaActionPort, type PlanRunResult } from "@handsoff/actions";
import {
  type CuaActionResult,
  type CuaActionRequest,
  type FinalTranscript,
  type GoalLoopObservation,
  type IntentInput,
  type PointingEvidence,
  type ResolvedIntent,
  type SupervisionAuditEvent,
  type SurfaceSnapshot,
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
const DEFAULT_MAX_GOAL_TICKS = 5;

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

type GoalRunState = {
  sessionId: string;
  baseInput: IntentInput;
  observations: readonly GoalLoopObservation[];
  nextTick: number;
  maxTicks: number;
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
  maxGoalTicks?: number;
}) {
  const [intent, setIntent] = useState<ResolvedIntent | null>(null);
  const [runResult, setRunResult] = useState<PlanRunResult | null>(null);
  const [session, setSession] = useState<SupervisionSession | null>(null);
  const [auditEvents, setAuditEvents] = useState<readonly SupervisionAuditEvent[]>([]);
  const audit = useRef(createActionAuditStore());
  const sessions = useRef(createSupervisionSessionStore());
  const goalRun = useRef<GoalRunState | null>(null);
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
    await wait(args.targetResolveDelayMs ?? DEFAULT_TARGET_RESOLVE_DELAY_MS);
    const createdAt = timestamp();
    const started = sessions.current.start(createdAt);
    const gesture = args.getGestureEvidence?.() ?? null;
    const headPointing = headPointingRef.current;
    const headCandidates = headPointing?.candidates ?? [];
    const pointingEvidence: PointingEvidence[] = gesture?.surface
      ? [gesture]
      : headPointing
        ? headCandidates.length > 0
          ? headCandidates.map((candidate) => ({
              source: "head" as const,
              confidence: candidate.score,
              strategy: "head-neighborhood",
              surface: candidate.surface,
              ...(headPointing.point && { cursor: headPointing.point }),
            }))
          : [
              {
                source: "head",
                confidence: 0,
                strategy: "head-neighborhood-empty",
                ...(headPointing.point && { cursor: headPointing.point }),
              },
            ]
        : [
            {
              source: "cursor",
              confidence: 1,
              strategy: "active-window-current-cursor",
              surface: await resolveActiveWindowSurface(),
            },
          ];
    const input: IntentInput = {
      sessionId: started.id,
      speech: { finalTranscript },
      pointingEvidence,
      surfaceCandidates: gesture?.surface
        ? [gesture.surface]
        : headPointing
          ? headCandidates.map((candidate) => candidate.surface)
          : pointingEvidence.flatMap((e) => (e.surface ? [e.surface] : [])),
    };
    const run: GoalRunState = {
      sessionId: started.id,
      baseInput: input,
      observations: [],
      nextTick: 0,
      maxTicks: args.maxGoalTicks ?? DEFAULT_MAX_GOAL_TICKS,
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

  function finishGoal(run: GoalRunState, status: TerminalSessionStatus, finishedAt: string) {
    const nextSession = sessions.current.finish(run.sessionId, status, finishedAt);
    setSession(nextSession);
    goalRun.current = null;
  }

  async function continueGoal(
    run: GoalRunState,
    createdAt: string,
    previousAction?: GoalLoopObservation["previousAction"],
  ) {
    if (run.nextTick >= run.maxTicks) {
      const input = inputForTick(run, run.nextTick, run.observations);
      const next = blockedIntent(
        input,
        `intent-max-ticks-${run.nextTick}`,
        createdAt,
        `Goal loop reached the max-tick safety bound (${run.maxTicks})`,
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
    // Diagnostic: the exact transcript + live observation handed to the intent engine.
    console.info("[handsoff] intent input", {
      transcript: input.speech.finalTranscript.text,
      tick: input.goalSession?.tick,
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
    const next =
      resolved.status === "ready" && resolved.action_plan.action_plan.length !== 1
        ? blockedIntent(
            input,
            `${resolved.id}-whole-plan-blocked`,
            createdAt,
            `Next-action resolver must return exactly one action per tick; got ${resolved.action_plan.action_plan.length}`,
          )
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

    const nextRun = {
      ...run,
      observations,
      nextTick: run.nextTick + 1,
    };
    goalRun.current = nextRun;
    if (next.requires_approval) return;
    await runGoalAction(nextRun, next);
  }

  async function runGoalAction(
    run: GoalRunState,
    readyIntent: Extract<ResolvedIntent, { status: "ready" }>,
    approval?: ReturnType<typeof makeApprovalDecision>,
  ) {
    const runningAt = timestamp();
    setSession(sessions.current.run(run.sessionId, runningAt));
    setRunResult({ status: "running" });
    const result = await runApprovedPlan({
      sessionId: run.sessionId,
      plan: readyIntent.action_plan,
      ...(approval ? { approval } : {}),
      cua: actionPortFor(args.driver),
      audit: audit.current,
      recordedAt: runningAt,
    });
    setRunResult(result);
    setAuditEvents(audit.current.forSession(run.sessionId));
    if (result.status !== "succeeded") {
      finishGoal(run, terminal(result.status), timestamp());
      return;
    }

    await continueGoal(run, timestamp(), {
      actionId: readyIntent.action_plan.id,
      result: actionResultFor(result, readyIntent.action_plan.summary),
    });
  }

  async function approve() {
    const run = goalRun.current;
    if (intent?.status !== "ready" || !session || !run) return;
    const runningAt = timestamp();
    await runGoalAction(
      run,
      intent,
      makeApprovalDecision(intent.action_plan.id, "approved", runningAt),
    );
  }

  async function reject() {
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
    setSession(sessions.current.finish(session.id, terminal(result.status), decidedAt));
    goalRun.current = null;
    setRunResult(result);
    setAuditEvents(audit.current.forSession(session.id));
  }

  return {
    intent,
    runResult,
    session,
    auditEvents,
    approve,
    reject,
    handleFinalTranscript: (finalTranscript: FinalTranscript) => void createIntent(finalTranscript),
  };
}
