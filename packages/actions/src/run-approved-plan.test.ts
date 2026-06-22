import { fakeActionTarget, fakeCuaActionResult, fakeCuaWindowState } from "@handsoff/testkit";
import { describe, expect, it } from "vitest";

import { runApprovedPlan } from "./run-approved-plan";
import type {
  ActionPlan,
  CuaActionRequest,
  CuaActionResult,
  SupervisionAuditEvent,
} from "@handsoff/contracts";
import type { CuaActionPort } from "./run-approved-plan";

function plan(overrides: Partial<ActionPlan> = {}): ActionPlan {
  return {
    id: "plan-1",
    summary: "Click the selected target",
    risk_level: "mutating",
    requires_approval: true,
    target_agent: "cua-driver",
    action_plan: [
      {
        id: "step-1",
        kind: "click_element",
        label: "Click selected target",
        target: fakeActionTarget(),
      },
    ],
    ...overrides,
  };
}

function port(
  result: CuaActionResult = fakeCuaActionResult(),
): CuaActionPort & { calls: CuaActionRequest[] } {
  const calls: CuaActionRequest[] = [];
  const state = fakeCuaActionResult({
    summary: "Window state captured",
    state: fakeCuaWindowState(),
  });
  return {
    calls,
    async getWindowState(request) {
      calls.push(request);
      return state;
    },
    async click(request) {
      calls.push(request);
      return result;
    },
    async typeText(request) {
      calls.push(request);
      return result;
    },
    async setValue(request) {
      calls.push(request);
      return result;
    },
    async screenshot(request) {
      calls.push(request);
      return result;
    },
  };
}

function auditSink() {
  let records: readonly SupervisionAuditEvent[] = [];
  return {
    record(event: SupervisionAuditEvent) {
      records = [...records, event];
      return event;
    },
    list() {
      return [...records];
    },
  };
}

describe("approved plan runner", () => {
  it("runs approved click plans as pre-state, action, post-state and stores fetched events", async () => {
    const cua = port();
    const audit = auditSink();

    const result = await runApprovedPlan({
      sessionId: "session-1",
      plan: plan(),
      approval: { actionId: "plan-1", decision: "approved", decidedAt: "2026-06-22T12:00:00.000Z" },
      cua,
      audit,
      recordedAt: "2026-06-22T12:00:00.000Z",
    });

    expect(result.status).toBe("succeeded");
    expect(cua.calls.map((call) => call.kind)).toEqual([
      "get_window_state",
      "click",
      "get_window_state",
    ]);
    expect(audit.list().map((event) => event.kind)).toEqual([
      "approval_decided",
      "cua_state_captured",
      "cua_call",
      "cua_state_captured",
      "execution_finished",
    ]);
  });

  it("blocks mutating plans without approval and makes no CUA calls", async () => {
    const cua = port();
    const audit = auditSink();

    const result = await runApprovedPlan({
      sessionId: "session-1",
      plan: plan(),
      cua,
      audit,
      recordedAt: "2026-06-22T12:00:00.000Z",
    });

    expect(result.status).toBe("blocked");
    expect(cua.calls).toEqual([]);
    expect(audit.list()).toMatchObject([{ kind: "execution_finished", status: "blocked" }]);
  });

  it("persists failed driver results", async () => {
    const cua = port({ status: "failed", error: "click failed" });
    const audit = auditSink();

    const result = await runApprovedPlan({
      sessionId: "session-1",
      plan: plan(),
      approval: { actionId: "plan-1", decision: "approved", decidedAt: "2026-06-22T12:00:00.000Z" },
      cua,
      audit,
      recordedAt: "2026-06-22T12:00:00.000Z",
    });

    expect(result).toEqual({
      status: "failed",
      result: { status: "failed", error: "click failed" },
    });
    expect(audit.list().at(-1)).toMatchObject({
      kind: "execution_finished",
      status: "failed",
      result: { error: "click failed" },
    });
  });

  it("stores rejected plans and performs no CUA calls", async () => {
    const cua = port();
    const audit = auditSink();

    const result = await runApprovedPlan({
      sessionId: "session-1",
      plan: plan(),
      approval: { actionId: "plan-1", decision: "rejected", decidedAt: "2026-06-22T12:00:00.000Z" },
      cua,
      audit,
      recordedAt: "2026-06-22T12:00:00.000Z",
    });

    expect(result.status).toBe("rejected");
    expect(cua.calls).toEqual([]);
    expect(audit.list()).toMatchObject([
      { kind: "approval_decided", approval: { decision: "rejected" } },
      { kind: "execution_finished", status: "rejected" },
    ]);
  });
});
