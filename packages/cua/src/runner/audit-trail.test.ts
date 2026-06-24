import { safeParseSupervisionAuditEvent } from "@handsoff/contracts";
import { describe, expect, it } from "vitest";

import type { LoopEntry } from "./computer-use-loop";
import { cuaTranscriptToAuditEvents } from "./audit-trail";

const ids = {
  sessionId: "session-1",
  actionId: "action-1",
  recordedAt: "2026-06-22T12:00:00.000Z",
};

describe("cuaTranscriptToAuditEvents", () => {
  it("maps an executed action to a ran event carrying the action and risk", () => {
    const transcript: LoopEntry[] = [
      {
        kind: "action",
        action: { kind: "click", elementIndex: 1 },
        risk: "mutating",
        outcome: { status: "ok" },
      },
    ];
    const [event] = cuaTranscriptToAuditEvents({ ...ids, transcript });
    expect(event).toMatchObject({
      kind: "cua_agent_action",
      sessionId: "session-1",
      actionId: "action-1",
      stepId: "cua-step-1",
      action: { kind: "click", elementIndex: 1 },
      risk: "mutating",
      status: "ran",
    });
  });

  it("maps an errored action to a failed event with the error as detail", () => {
    const transcript: LoopEntry[] = [
      {
        kind: "action",
        action: { kind: "snapshot" },
        risk: "read_only",
        outcome: { status: "error", error: "display locked" },
      },
    ];
    const [event] = cuaTranscriptToAuditEvents({ ...ids, transcript });
    expect(event).toMatchObject({ status: "failed", detail: "display locked" });
  });

  it("maps a gate-blocked entry to a blocked event with the reason as detail", () => {
    const transcript: LoopEntry[] = [
      {
        kind: "blocked",
        action: { kind: "type_text", elementIndex: 0, text: "x" },
        risk: "mutating",
        reason: "Blocked type (mutating) pending approval",
      },
    ];
    const [event] = cuaTranscriptToAuditEvents({ ...ids, transcript });
    expect(event).toMatchObject({
      status: "blocked",
      detail: "Blocked type (mutating) pending approval",
    });
  });

  it("skips assistant narration and numbers steps over the emitted events only", () => {
    const transcript: LoopEntry[] = [
      { kind: "assistant", text: "thinking" },
      {
        kind: "action",
        action: { kind: "snapshot" },
        risk: "read_only",
        outcome: { status: "ok" },
      },
      { kind: "assistant", text: "clicking" },
      {
        kind: "action",
        action: { kind: "click", elementIndex: 3 },
        risk: "mutating",
        outcome: { status: "ok" },
      },
    ];
    const events = cuaTranscriptToAuditEvents({ ...ids, transcript });
    expect(events).toHaveLength(2);
    expect(events.map((e) => e.kind)).toEqual(["cua_agent_action", "cua_agent_action"]);
    expect(events.map((e) => (e.kind === "cua_agent_action" ? e.stepId : ""))).toEqual([
      "cua-step-1",
      "cua-step-2",
    ]);
  });

  it("emits events that validate against the audit contract", () => {
    const transcript: LoopEntry[] = [
      {
        kind: "action",
        action: { kind: "click", elementIndex: 1 },
        risk: "mutating",
        outcome: { status: "ok" },
      },
      {
        kind: "blocked",
        action: { kind: "type_text", elementIndex: 0, text: "x" },
        risk: "mutating",
        reason: "pending approval",
      },
    ];
    for (const event of cuaTranscriptToAuditEvents({ ...ids, transcript })) {
      expect(safeParseSupervisionAuditEvent(event).success).toBe(true);
    }
  });
});
