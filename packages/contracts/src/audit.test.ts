import { describe, expect, it } from "vitest";

import { safeParseSurfaceSelectionRecord } from "./audit";
import type { SurfaceSelectionRecord } from "./audit";

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
