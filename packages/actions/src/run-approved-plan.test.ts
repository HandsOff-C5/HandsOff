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
  options: {
    result?: CuaActionResult;
    stateResult?: CuaActionResult;
    stateResults?: CuaActionResult[];
  } = {},
): CuaActionPort & { calls: CuaActionRequest[] } {
  const calls: CuaActionRequest[] = [];
  let stateIndex = 0;
  const state =
    options.stateResult ??
    fakeCuaActionResult({
      summary: "Window state captured",
      state: fakeCuaWindowState(),
    });
  const result = options.result ?? fakeCuaActionResult();
  return {
    calls,
    async launchApp(request) {
      calls.push(request);
      return result;
    },
    async getWindowState(request) {
      calls.push(request);
      if (options.stateResults) return options.stateResults[stateIndex++] ?? state;
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
    const cua = port({ result: { status: "failed", error: "click failed" } });
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

  it("does not fail a successful action when post-state capture fails", async () => {
    const cua = port({
      result: { status: "succeeded", summary: "Typed dictated text" },
      stateResults: [
        fakeCuaActionResult({
          summary: "Window state captured",
          state: fakeCuaWindowState(),
        }),
        { status: "failed", error: "Post-action CUA state capture did not return state" },
      ],
    });
    const audit = auditSink();

    const result = await runApprovedPlan({
      sessionId: "session-1",
      plan: plan({
        action_plan: [
          {
            id: "step-1",
            kind: "type_text",
            label: "Type dictated text",
            target: fakeActionTarget(),
            text: "hello",
          },
        ],
      }),
      approval: { actionId: "plan-1", decision: "approved", decidedAt: "2026-06-22T12:00:00.000Z" },
      cua,
      audit,
      recordedAt: "2026-06-22T12:00:00.000Z",
    });

    expect(result.status).toBe("succeeded");
    expect(cua.calls.map((call) => call.kind)).toEqual([
      "get_window_state",
      "type_text",
      "get_window_state",
    ]);
    expect(audit.list().at(-1)).toMatchObject({ kind: "execution_finished", status: "succeeded" });
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

  it("runs app-launch steps before target actions", async () => {
    const cua = port();
    const audit = auditSink();
    const target = fakeActionTarget({
      surface: {
        id: "app:textedit",
        title: "TextEdit",
        app: "TextEdit",
        availability: "unknown",
        accessStatus: "unknown",
      },
    });

    const result = await runApprovedPlan({
      sessionId: "session-1",
      plan: plan({
        action_plan: [
          { id: "step-1", kind: "launch_app", label: "Open TextEdit", appName: "TextEdit" },
          {
            id: "step-2",
            kind: "type_text",
            label: "Type dictated text",
            target,
            text: "hello goodbye",
          },
        ],
      }),
      approval: { actionId: "plan-1", decision: "approved", decidedAt: "2026-06-22T12:00:00.000Z" },
      cua,
      audit,
      recordedAt: "2026-06-22T12:00:00.000Z",
    });

    expect(result.status).toBe("succeeded");
    expect(cua.calls.map((call) => call.kind)).toEqual([
      "launch_app",
      "get_window_state",
      "type_text",
      "get_window_state",
    ]);
    expect(audit.list().filter((event) => event.kind === "cua_call")).toHaveLength(2);
  });

  it("blocks before mutation when pre-action state capture is blocked", async () => {
    const cua = port({ stateResult: { status: "blocked", reason: "No accessible target" } });
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
      status: "blocked",
      result: { status: "blocked", reason: "No accessible target" },
    });
    expect(cua.calls.map((call) => call.kind)).toEqual(["get_window_state"]);
    expect(audit.list().map((event) => event.kind)).toEqual([
      "approval_decided",
      "execution_finished",
    ]);
  });
});
