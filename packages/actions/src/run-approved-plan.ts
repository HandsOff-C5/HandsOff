import { riskForToolCall, riskLevelRequiresApproval } from "@handsoff/contracts";
import type {
  ActionPlan,
  ApprovalDecision,
  CuaActionRequest,
  CuaActionResult,
  CuaWindowState,
  DriverTool,
  ExecutionStatus,
  RiskLevel,
  SupervisionAuditEvent,
  ToolCallTarget,
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
  const matchingApproval =
    args.approval && args.approval.actionId === args.plan.id ? args.approval : undefined;

  if (matchingApproval) {
    args.audit.record({
      kind: "approval_decided",
      sessionId: args.sessionId,
      actionId: args.plan.id,
      recordedAt,
      approval: matchingApproval,
    });
  }

  const requiredApproval = requiredApprovalResult(args.plan, matchingApproval, args.approval);
  if (requiredApproval) {
    args.audit.record({
      kind: "execution_finished",
      sessionId: args.sessionId,
      actionId: args.plan.id,
      recordedAt,
      status: requiredApproval.status,
      ...(requiredApproval.result && { result: requiredApproval.result }),
    });
    return requiredApproval;
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
      continue;
    }

    // A generic `tool_call` step (U3b full-surface) is dispatched through the
    // driver passthrough by the autonomous loop, not this typed executor. It has
    // no ActionTarget for pre/post window capture, so it cannot run here — fail
    // loudly rather than silently mis-handle it (a routing bug if it occurs).
    if (step.kind === "tool_call") {
      const result: CuaActionResult = {
        status: "failed",
        error: `runApprovedPlan cannot execute a generic tool_call step (${step.tool}); the autonomous loop dispatches it via driver.call`,
      };
      finish(args.audit, args.sessionId, args.plan.id, recordedAt, result);
      return { status: "failed", result };
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

function requiredApprovalResult(
  plan: ActionPlan,
  matchingApproval: ApprovalDecision | undefined,
  providedApproval: ApprovalDecision | undefined,
): PlanRunResult | null {
  if (!riskLevelRequiresApproval(plan.risk_level)) return null;
  if (matchingApproval?.decision === "approved") return null;
  if (matchingApproval?.decision === "rejected") return { status: "rejected" };

  const reason =
    providedApproval && providedApproval.actionId !== plan.id
      ? "Approval decision does not match this action plan"
      : `Approval required before executing ${riskLabel(plan.risk_level)} plan`;
  return { status: "blocked", result: { status: "blocked", reason } };
}

function riskLabel(riskLevel: ActionPlan["risk_level"]): string {
  return riskLevel === "destructive_external" ? "destructive/external" : riskLevel;
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

// Per-call gate for the agentic loop (U3 wires this in; this unit only provides
// the pure helper). Mirrors `requiredApprovalResult` above but keyed on a single
// tool call instead of a whole ActionPlan: the gate is DERIVED from the tool's
// risk (via `riskForToolCall`) and NEVER from a model-supplied claim, so a model
// that labels a `click` on "Send" as read_only cannot bypass approval.
//
// `allowed` is true when the call may run now: either its risk auto-runs
// (read_only/reversible) or a matching approval has been granted. When blocked,
// `result` carries the same shape `runApprovedPlan` records, so the loop can
// audit it identically.
export type ToolCallGateResult =
  | { allowed: true; risk: RiskLevel }
  | { allowed: false; risk: RiskLevel; result: Extract<CuaActionResult, { status: "blocked" }> };

export function gateToolCall(args: {
  tool: DriverTool;
  target?: ToolCallTarget;
  approved?: boolean;
}): ToolCallGateResult {
  const risk = riskForToolCall(args.tool, args.target);
  if (!riskLevelRequiresApproval(risk)) return { allowed: true, risk };
  if (args.approved) return { allowed: true, risk };
  return {
    allowed: false,
    risk,
    result: {
      status: "blocked",
      reason: `Approval required before executing ${riskLabel(risk)} tool ${args.tool}`,
    },
  };
}
