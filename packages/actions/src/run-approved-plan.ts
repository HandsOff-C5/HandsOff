import type {
  ActionPlan,
  ApprovalDecision,
  CuaActionRequest,
  CuaActionResult,
  CuaWindow,
  CuaWindowState,
  ExecutionStatus,
  SupervisionAuditEvent,
} from "@handsoff/contracts";

import { translateStep } from "./translate-plan";

export type CuaActionPort = {
  launchApp(request: Extract<CuaActionRequest, { kind: "launch_app" }>): Promise<CuaActionResult>;
  getWindowState(
    request: Extract<CuaActionRequest, { kind: "get_window_state" }>,
  ): Promise<CuaActionResult>;
  click(request: Extract<CuaActionRequest, { kind: "click" }>): Promise<CuaActionResult>;
  typeText(request: Extract<CuaActionRequest, { kind: "type_text" }>): Promise<CuaActionResult>;
  setValue(request: Extract<CuaActionRequest, { kind: "set_value" }>): Promise<CuaActionResult>;
  screenshot(request: Extract<CuaActionRequest, { kind: "screenshot" }>): Promise<CuaActionResult>;
  // Lists on-screen windows — used to VERIFY a launch actually happened (the OS shows the
  // app), rather than trusting the launch command's own success report.
  listWindows(): Promise<readonly CuaWindow[]>;
};

// Did a window for `appName` actually appear? Matches the app name case-insensitively
// either way (so "Cursor" matches a "Cursor" window and tolerates ".app" suffixes).
export function appWindowPresent(
  windows: readonly CuaWindow[],
  appName: string,
): { present: boolean; focused: boolean } {
  const wanted = appName.trim().toLowerCase();
  const match = windows.find((w) => {
    const app = w.app.trim().toLowerCase();
    return app === wanted || app.includes(wanted) || wanted.includes(app);
  });
  return { present: match !== undefined, focused: match?.focused === true };
}

const DEFAULT_LAUNCH_VERIFY = { attempts: 6, delayMs: 400 };
const realWait = (ms: number): Promise<void> => new Promise((resolve) => setTimeout(resolve, ms));

export type ActionAuditSink = {
  record(event: SupervisionAuditEvent): SupervisionAuditEvent;
};

export type PlanRunResult = {
  status: ExecutionStatus;
  result?: CuaActionResult;
};

export async function runApprovedPlan(args: {
  sessionId: string;
  plan: ActionPlan;
  approval?: ApprovalDecision;
  cua: CuaActionPort;
  audit: ActionAuditSink;
  recordedAt?: string;
  // Launch verification poll (how many times / how long to wait for the app's window to
  // appear) and the wait fn (injected so tests run instantly). An app cold-start can take
  // a couple of seconds, so we poll rather than check once.
  launchVerify?: { attempts?: number; delayMs?: number };
  wait?: (ms: number) => Promise<void>;
}): Promise<PlanRunResult> {
  const recordedAt = args.recordedAt ?? new Date().toISOString();
  const verifyAttempts = args.launchVerify?.attempts ?? DEFAULT_LAUNCH_VERIFY.attempts;
  const verifyDelayMs = args.launchVerify?.delayMs ?? DEFAULT_LAUNCH_VERIFY.delayMs;
  const wait = args.wait ?? realWait;

  if (args.approval) {
    args.audit.record({
      kind: "approval_decided",
      sessionId: args.sessionId,
      actionId: args.plan.id,
      recordedAt,
      approval: args.approval,
    });
  }

  if (args.plan.requires_approval && args.approval?.decision !== "approved") {
    const status = args.approval?.decision === "rejected" ? "rejected" : "blocked";
    args.audit.record({
      kind: "execution_finished",
      sessionId: args.sessionId,
      actionId: args.plan.id,
      recordedAt,
      status,
    });
    return { status };
  }

  for (const step of args.plan.action_plan) {
    if (step.kind === "launch_app") {
      const request = translateStep(step);
      const result = await callCua(args.cua, request);
      args.audit.record({
        kind: "cua_call",
        sessionId: args.sessionId,
        actionId: args.plan.id,
        stepId: step.id,
        recordedAt,
        request,
        result,
      });
      if (result.status !== "succeeded") {
        finish(args.audit, args.sessionId, args.plan.id, recordedAt, result);
        return { status: result.status, result };
      }

      // SEMANTIC verification (DoD): don't just trust the launch report — confirm the OS
      // shows the app by polling the window list until it appears. When the window list
      // is unavailable (no CUA daemon), we rely on the launch command's own OS-level
      // result (`open -a` only succeeds if LaunchServices launched the app) rather than
      // failing a launch we can't independently observe.
      const appName = step.appName;
      let verifiedByWindow = false;
      let windowListAvailable = true;
      try {
        let verification = appWindowPresent(await args.cua.listWindows(), appName);
        for (let left = verifyAttempts - 1; !verification.present && left > 0; left -= 1) {
          await wait(verifyDelayMs);
          verification = appWindowPresent(await args.cua.listWindows(), appName);
        }
        verifiedByWindow = verification.present;
      } catch {
        windowListAvailable = false;
      }
      if (!verifiedByWindow && windowListAvailable) {
        const failure: CuaActionResult = {
          status: "failed",
          error: `Launched ${appName} but no ${appName} window appeared — launch not verified`,
        };
        finish(args.audit, args.sessionId, args.plan.id, recordedAt, failure);
        return { status: "failed", result: failure };
      }
      continue;
    }

    const pre = await args.cua.getWindowState({ kind: "get_window_state", target: step.target });
    const preCapture = stateCapture(pre, "Pre-action");
    if ("failure" in preCapture) {
      finish(args.audit, args.sessionId, args.plan.id, recordedAt, preCapture.failure);
      return { status: preCapture.failure.status, result: preCapture.failure };
    }
    recordState(
      args.audit,
      args.sessionId,
      args.plan.id,
      step.id,
      "pre",
      recordedAt,
      preCapture.state,
    );

    const request = translateStep(step);
    const result = await callCua(args.cua, request);
    args.audit.record({
      kind: "cua_call",
      sessionId: args.sessionId,
      actionId: args.plan.id,
      stepId: step.id,
      recordedAt,
      request,
      result,
    });

    const postRequest: Extract<CuaActionRequest, { kind: "get_window_state" }> = {
      kind: "get_window_state",
      target: step.target,
    };
    const post = await args.cua.getWindowState(postRequest);
    const postCapture = stateCapture(post, "Post-action");
    if ("failure" in postCapture) {
      args.audit.record({
        kind: "cua_call",
        sessionId: args.sessionId,
        actionId: args.plan.id,
        stepId: step.id,
        recordedAt,
        request: postRequest,
        result: postCapture.failure,
      });
    } else {
      recordState(
        args.audit,
        args.sessionId,
        args.plan.id,
        step.id,
        "post",
        recordedAt,
        postCapture.state,
      );
    }

    if (result.status !== "succeeded") {
      finish(args.audit, args.sessionId, args.plan.id, recordedAt, result);
      return { status: result.status, result };
    }
  }

  args.audit.record({
    kind: "execution_finished",
    sessionId: args.sessionId,
    actionId: args.plan.id,
    recordedAt,
    status: "succeeded",
  });
  return { status: "succeeded" };
}

async function callCua(port: CuaActionPort, request: CuaActionRequest): Promise<CuaActionResult> {
  if (request.kind === "launch_app") {
    return port.launchApp(request);
  }
  if (request.kind === "get_window_state") {
    return port.getWindowState(request);
  }
  if (request.kind === "click") {
    return port.click(request);
  }
  if (request.kind === "type_text") {
    return port.typeText(request);
  }
  if (request.kind === "set_value") {
    return port.setValue(request);
  }
  return port.screenshot(request);
}

function stateCapture(
  result: CuaActionResult,
  phase: string,
): { state: CuaWindowState } | { failure: CuaActionResult } {
  if (result.status !== "succeeded") return { failure: result };
  if (result.state) return { state: result.state };
  return {
    failure: { status: "failed", error: `${phase} CUA state capture did not return state` },
  };
}

function finish(
  audit: ActionAuditSink,
  sessionId: string,
  actionId: string,
  recordedAt: string,
  result: CuaActionResult,
): void {
  audit.record({
    kind: "execution_finished",
    sessionId,
    actionId,
    recordedAt,
    status: result.status,
    result,
  });
}

function recordState(
  audit: ActionAuditSink,
  sessionId: string,
  actionId: string,
  stepId: string,
  phase: "pre" | "post",
  recordedAt: string,
  state: CuaWindowState,
) {
  audit.record({
    kind: "cua_state_captured",
    sessionId,
    actionId,
    stepId,
    phase,
    recordedAt,
    state,
  });
}
