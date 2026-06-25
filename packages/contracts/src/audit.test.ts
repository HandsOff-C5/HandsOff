import { describe, expect, it } from "vitest";

import { safeParseSupervisionAuditEvent, safeParseSurfaceSelectionRecord } from "./audit";
import type { SupervisionAuditEvent, SurfaceSelectionRecord } from "./audit";

function validRecord(): SurfaceSelectionRecord {
  return {
    referent: { id: "ref-1", source: "gesture", confidence: 0.82 },
    surface: {
      id: "surface-1",
      title: "issue #23 — GitHub",
      app: "Google Chrome",
      pid: 4210,
      windowId: 71,
      availability: "available",
      accessStatus: "accessible",
    },
    sessionId: "session-1",
    actionId: "action-1",
    selectedAt: "2026-06-20T12:00:00.000Z",
  };
}

describe("surface selection audit record contract", () => {
  it("accepts a complete selection record", () => {
    const result = safeParseSurfaceSelectionRecord(validRecord());
    expect(result.success).toBe(true);
  });

  it("accepts a record without an action id (selection precedes the action)", () => {
    const base = validRecord();
    const result = safeParseSurfaceSelectionRecord({
      referent: base.referent,
      surface: base.surface,
      sessionId: base.sessionId,
      selectedAt: base.selectedAt,
    });
    expect(result.success).toBe(true);
  });

  it("rejects a confidence outside [0,1]", () => {
    const base = validRecord();
    const result = safeParseSurfaceSelectionRecord({
      ...base,
      referent: { ...base.referent, confidence: 1.4 },
    });
    expect(result.success).toBe(false);
  });

  it("rejects an unknown referent source", () => {
    const base = validRecord();
    const result = safeParseSurfaceSelectionRecord({
      ...base,
      referent: { ...base.referent, source: "telepathy" },
    });
    expect(result.success).toBe(false);
  });

  it("rejects an empty referent id", () => {
    const base = validRecord();
    const result = safeParseSurfaceSelectionRecord({
      ...base,
      referent: { ...base.referent, id: "" },
    });
    expect(result.success).toBe(false);
  });

  it("rejects a record with no session link", () => {
    const base = validRecord();
    const result = safeParseSurfaceSelectionRecord({
      referent: base.referent,
      surface: base.surface,
      actionId: base.actionId,
      selectedAt: base.selectedAt,
    });
    expect(result.success).toBe(false);
  });

  it("rejects a non-ISO selection timestamp", () => {
    const base = validRecord();
    const result = safeParseSurfaceSelectionRecord({ ...base, selectedAt: "yesterday" });
    expect(result.success).toBe(false);
  });
});

describe("supervision audit event contract", () => {
  it("round-trips a fetched CUA call event", () => {
    const event: SupervisionAuditEvent = {
      kind: "cua_call",
      sessionId: "session-1",
      actionId: "action-1",
      stepId: "step-1",
      recordedAt: "2026-06-22T12:00:00.000Z",
      request: {
        kind: "click",
        target: { surface: validRecord().surface, elementIndex: 0 },
      },
      result: {
        status: "succeeded",
        summary: "Clicked selected target",
      },
    };

    const result = safeParseSupervisionAuditEvent(event);

    expect(result.success).toBe(true);
    expect(result.success && result.data).toEqual(event);
  });

  it("rejects approval events that point at a different action", () => {
    const result = safeParseSupervisionAuditEvent({
      kind: "approval_decided",
      sessionId: "session-1",
      actionId: "action-1",
      recordedAt: "2026-06-22T12:00:00.000Z",
      approval: {
        actionId: "action-2",
        decision: "approved",
        decidedAt: "2026-06-22T12:00:00.000Z",
      },
    });

    expect(result.success).toBe(false);
  });

  it("rejects audit events with no action link", () => {
    const result = safeParseSupervisionAuditEvent({
      kind: "execution_finished",
      sessionId: "session-1",
      recordedAt: "2026-06-22T12:00:00.000Z",
      status: "succeeded",
    });

    expect(result.success).toBe(false);
  });
});
