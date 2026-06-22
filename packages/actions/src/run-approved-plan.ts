import type {
  ActionPlan,
  ApprovalDecision,
  CuaActionRequest,
  CuaActionResult,
  ExecutionStatus,
  SupervisionAuditEvent,
} from "@handsoff/contracts";

import { translateStep } from "./translate-plan";

export type CuaActionPort = {
  getWindowState(
    request: Extract<CuaActionRequest, { kind: "get_window_state" }>,
  ): Promise<CuaActionResult>;
  click(request: Extract<CuaActionRequest, { kind: "click" }>): Promise<CuaActionResult>;
  typeText(request: Extract<CuaActionRequest, { kind: "type_text" }>): Promise<CuaActionResult>;
  setValue(request: Extract<CuaActionRequest, { kind: "set_value" }>): Promise<CuaActionResult>;
  screenshot(request: Extract<CuaActionRequest, { kind: "screenshot" }>): Promise<CuaActionResult>;
};

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
}): Promise<PlanRunResult> {
  const recordedAt = args.recordedAt ?? new Date().toISOString();

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
    const pre = await args.cua.getWindowState({ kind: "get_window_state", target: step.target });
    recordState(args.audit, args.sessionId, args.plan.id, step.id, "pre", recordedAt, pre);

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

    const post = await args.cua.getWindowState({ kind: "get_window_state", target: step.target });
    recordState(args.audit, args.sessionId, args.plan.id, step.id, "post", recordedAt, post);

    if (result.status !== "succeeded") {
      args.audit.record({
        kind: "execution_finished",
        sessionId: args.sessionId,
        actionId: args.plan.id,
        recordedAt,
        status: result.status,
        result,
      });
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

function recordState(
  audit: ActionAuditSink,
  sessionId: string,
  actionId: string,
  stepId: string,
  phase: "pre" | "post",
  recordedAt: string,
  result: CuaActionResult,
) {
  if (!result.state) {
    return;
  }
  audit.record({
    kind: "cua_state_captured",
    sessionId,
    actionId,
    stepId,
    phase,
    recordedAt,
    state: result.state,
  });
}
