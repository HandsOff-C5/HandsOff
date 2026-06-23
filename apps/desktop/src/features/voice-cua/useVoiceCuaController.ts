import { runApprovedPlan, type CuaActionPort, type PlanRunResult } from "@handsoff/actions";
import {
  type CuaActionRequest,
  type FinalTranscript,
  type IntentInput,
  type PointingEvidence,
  type ResolvedIntent,
  type SupervisionAuditEvent,
  type SurfaceSnapshot,
} from "@handsoff/contracts";
import type { CuaDriver } from "@handsoff/cua";
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

// The active-window fallback referent: used when neither a locked gesture nor a
// head/gaze candidate is present, so a pure voice command still binds to *something*.
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
    launchApp: ({ appName, bundleId }: Extract<CuaActionRequest, { kind: "launch_app" }>) =>
      driver.launchApp({ appName, bundleId }),
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
}) {
  const [intent, setIntent] = useState<ResolvedIntent | null>(null);
  const [runResult, setRunResult] = useState<PlanRunResult | null>(null);
  const [session, setSession] = useState<SupervisionSession | null>(null);
  const [auditEvents, setAuditEvents] = useState<readonly SupervisionAuditEvent[]>([]);
  const audit = useRef(createActionAuditStore());
  const sessions = useRef(createSupervisionSessionStore());
  const headPointingRef = useRef(args.headPointing);
  const resolveIntentRef = useRef(args.resolveIntent ?? resolveIntent);
  headPointingRef.current = args.headPointing;
  resolveIntentRef.current = args.resolveIntent ?? resolveIntent;
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
    // Gather pointing evidence from every live modality and let fusion arbitrate by
    // confidence: the locked gesture referent (#35) and the head/gaze attention
    // candidates (#95). When neither is present, fall back to the active-window cursor
    // probe so a pure voice command (e.g. "open Cursor") still binds to something.
    const gesture = args.getGestureEvidence?.() ?? null;
    const headPointing = headPointingRef.current;
    const pointingEvidence: PointingEvidence[] = gesture ? [gesture] : [];

    if (headPointing) {
      const headCandidates = headPointing.candidates ?? [];
      if (headCandidates.length > 0) {
        for (const candidate of headCandidates) {
          pointingEvidence.push({
            source: "head",
            confidence: candidate.score,
            strategy: "head-neighborhood",
            surface: candidate.surface,
            ...(headPointing.point && { cursor: headPointing.point }),
          });
        }
      } else if (!gesture) {
        // Head tracking is active but nothing is under the gaze: emit an empty sentinel
        // so fusion clarifies rather than silently retargeting the active window.
        pointingEvidence.push({
          source: "head",
          confidence: 0,
          strategy: "head-neighborhood-empty",
          ...(headPointing.point && { cursor: headPointing.point }),
        });
      }
    }

    if (pointingEvidence.length === 0) {
      // No live pointing modality at all → active-window cursor probe so a pure voice
      // command still binds to something.
      pointingEvidence.push({
        source: "cursor",
        confidence: 1,
        strategy: "active-window-current-cursor",
        surface: await resolveActiveWindowSurface(),
      });
    }

    const input: IntentInput = {
      sessionId: started.id,
      speech: { finalTranscript },
      pointingEvidence,
      surfaceCandidates: pointingEvidence.flatMap((e) => (e.surface ? [e.surface] : [])),
    };
    const next = await resolveIntentRef.current(input, { resolver: "auto", createdAt });
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
    setAuditEvents(audit.current.forSession(started.id));
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
    setAuditEvents(audit.current.forSession(session.id));
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
