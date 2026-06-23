import { runApprovedPlan, type CuaActionPort, type PlanRunResult } from "@handsoff/actions";
import {
  type CuaActionRequest,
  type FinalTranscript,
  type IntentInput,
  type ResolvedIntent,
  type SupervisionAuditEvent,
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

  async function createIntent(finalTranscript: FinalTranscript) {
    await wait(args.targetResolveDelayMs ?? DEFAULT_TARGET_RESOLVE_DELAY_MS);
    const createdAt = timestamp();
    const started = sessions.current.start(createdAt);
    const headPointing = headPointingRef.current;
    const headCandidates = headPointing?.candidates ?? [];
    const input: IntentInput = {
      sessionId: started.id,
      speech: { finalTranscript },
      pointingEvidence:
        headCandidates.length > 0
          ? headCandidates.map((candidate) => ({
              source: "head" as const,
              confidence: candidate.score,
              strategy: "head-neighborhood",
              surface: candidate.surface,
              ...(headPointing?.point && { cursor: headPointing.point }),
            }))
          : [
              {
                source: "head",
                confidence: 0,
                strategy: "head-neighborhood-empty",
                ...(headPointing?.point && { cursor: headPointing.point }),
              },
            ],
      surfaceCandidates: headCandidates.map((candidate) => candidate.surface),
    };
    // Diagnostic: the exact transcript + head evidence handed to the intent engine.
    // `surfaceCandidates: []` here is the "No attention-region candidates" path.
    console.info("[handsoff] intent input", {
      transcript: finalTranscript.text,
      headPoint: headPointing?.point ?? null,
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
    const next = await resolveIntentRef.current(input, { resolver: "auto", createdAt });
    console.info("[handsoff] intent result", {
      status: next.status,
      reason: "reason" in next ? next.reason : undefined,
      referent: "referent" in next ? next.referent : undefined,
      planSteps:
        "action_plan" in next ? next.action_plan.action_plan.map((s) => s.kind) : undefined,
    });
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
