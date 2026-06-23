import { runApprovedPlan, type CuaActionPort, type PlanRunResult } from "@handsoff/actions";
import {
  type CuaActionRequest,
  type FinalTranscript,
  type PointingEvidence,
  type SurfaceSnapshot,
} from "@handsoff/contracts";
import type { CuaDriver } from "@handsoff/cua";
import { fuseIntent } from "@handsoff/intent";
import {
  createActionAuditStore,
  createSupervisionSessionStore,
  type SupervisionSession,
  type TerminalSessionStatus,
} from "@handsoff/supervision";
import { useRef, useState } from "react";

import { makeApprovalDecision } from "../plan-preview/usePlanApproval";

const ACTIVE_WINDOW_SURFACE: SurfaceSnapshot = {
  id: "active-window",
  title: "Active window",
  app: "Current app",
  availability: "available",
  accessStatus: "accessible",
};

// ponytail: fixed retarget grace; make it configurable if manual testing proves one size wrong.
const DEFAULT_TARGET_RESOLVE_DELAY_MS = 1500;

function wait(ms: number): Promise<void> {
  return ms > 0 ? new Promise((resolve) => setTimeout(resolve, ms)) : Promise.resolve();
}

function actionPortFor(driver: CuaDriver): CuaActionPort {
  return {
    getWindowState: ({ target }: Extract<CuaActionRequest, { kind: "get_window_state" }>) =>
      driver.getWindowState(target),
    click: ({ target }: Extract<CuaActionRequest, { kind: "click" }>) => driver.click(target),
    typeText: ({ target, text }: Extract<CuaActionRequest, { kind: "type_text" }>) =>
      driver.typeText(target, text),
    setValue: ({ target, value }: Extract<CuaActionRequest, { kind: "set_value" }>) =>
      driver.setValue(target, value),
    screenshot: ({ target }: Extract<CuaActionRequest, { kind: "screenshot" }>) =>
      driver.screenshot(target),
  };
}

function terminal(status: PlanRunResult["status"]): TerminalSessionStatus {
  if (status === "queued" || status === "running") {
    throw new Error(`Cannot finish session with non-terminal status: ${status}`);
  }
  return status;
}

export function useVoiceCuaController(args: {
  driver: CuaDriver;
  now?: () => string;
  targetResolveDelayMs?: number;
  // The live gesture referent (#35): when the camera has a locked point at intent
  // time it returns gesture `PointingEvidence`; null when nothing is locked.
  getGestureEvidence?: () => PointingEvidence | null;
}) {
  const [intent, setIntent] = useState<ReturnType<typeof fuseIntent> | null>(null);
  const [runResult, setRunResult] = useState<PlanRunResult | null>(null);
  const [session, setSession] = useState<SupervisionSession | null>(null);
  const audit = useRef(createActionAuditStore());
  const sessions = useRef(createSupervisionSessionStore());
  const timestamp = () => args.now?.() ?? new Date().toISOString();

  // Cursor fallback: probe the active window via the CUA driver, degrading the
  // surface to "unknown" availability/access when the probe doesn't succeed.
  async function resolveActiveWindowSurface(): Promise<SurfaceSnapshot> {
    const resolved = await args.driver.getWindowState({ surface: ACTIVE_WINDOW_SURFACE });
    return resolved.status === "succeeded" && resolved.state
      ? resolved.state.surface
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
    // Prefer the live gesture referent (#35) — what the user actually pointed at.
    // Only when nothing is locked do we fall back to the active-window cursor probe.
    const gesture = args.getGestureEvidence?.() ?? null;
    const pointingEvidence: PointingEvidence[] = gesture?.surface
      ? [gesture]
      : [
          {
            source: "cursor",
            confidence: 1,
            strategy: "active-window-current-cursor",
            surface: await resolveActiveWindowSurface(),
          },
        ];
    const next = fuseIntent(
      {
        sessionId: started.id,
        speech: { finalTranscript },
        pointingEvidence,
        surfaceCandidates: pointingEvidence.flatMap((e) => (e.surface ? [e.surface] : [])),
      },
      { createdAt },
    );
    const nextSession =
      next.status === "ready" ? started : sessions.current.finish(started.id, "blocked", createdAt);
    setSession(nextSession);
    setIntent(next);
    setRunResult(null);
    audit.current.record({
      kind: "intent_created",
      sessionId: started.id,
      actionId: next.status === "ready" ? next.action_plan.id : next.id,
      recordedAt: createdAt,
      intent: next,
    });
  }

  async function approve() {
    if (intent?.status !== "ready" || !session) return;
    const runningAt = timestamp();
    setSession(sessions.current.run(session.id, runningAt));
    setRunResult({ status: "running" });
    const result = await runApprovedPlan({
      sessionId: session.id,
      plan: intent.action_plan,
      approval: makeApprovalDecision(intent.action_plan.id, "approved", runningAt),
      cua: actionPortFor(args.driver),
      audit: audit.current,
      recordedAt: runningAt,
    });
    setSession(sessions.current.finish(session.id, terminal(result.status), timestamp()));
    setRunResult(result);
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
    setRunResult(result);
  }

  return {
    intent,
    runResult,
    session,
    approve,
    reject,
    handleFinalTranscript: (finalTranscript: FinalTranscript) => void createIntent(finalTranscript),
  };
}
