import { fakeActionTarget, fakeCuaActionResult } from "@handsoff/testkit";
import { describe, expect, it } from "vitest";

import { createActionAuditStore } from "./action-store";

describe("action audit store", () => {
  it("persists and fetches exact CUA call records", () => {
    const store = createActionAuditStore();
    const recorded = store.record({
      kind: "cua_call",
      sessionId: "session-1",
      actionId: "plan-1",
      stepId: "step-1",
      recordedAt: "2026-06-22T12:00:00.000Z",
      request: { kind: "click", target: fakeActionTarget() },
      result: fakeCuaActionResult(),
    });

    expect(store.list()).toEqual([recorded]);
    expect(store.forSession("session-1")).toEqual([recorded]);
    expect(store.forAction("plan-1")).toEqual([recorded]);
  });

  it("rejects invalid records and keeps the log unchanged", () => {
    const store = createActionAuditStore();

    expect(() =>
      store.record({
        kind: "execution_finished",
        sessionId: "session-1",
        actionId: "",
        recordedAt: "2026-06-22T12:00:00.000Z",
        status: "succeeded",
      }),
    ).toThrow(/invalid supervision audit event/i);
    expect(store.list()).toEqual([]);
  });
});
