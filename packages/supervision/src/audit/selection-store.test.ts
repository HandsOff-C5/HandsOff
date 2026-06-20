import type { SurfaceSelectionRecord } from "@handsoff/contracts";
import { describe, expect, it } from "vitest";

import { createSelectionAuditStore } from "./selection-store";

function makeRecord(overrides: Partial<SurfaceSelectionRecord> = {}): SurfaceSelectionRecord {
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
    ...overrides,
  };
}

describe("selection audit store", () => {
  it("persists a selection and fetches back the exact selected referent fields", () => {
    const store = createSelectionAuditStore();
    const recorded = store.record(makeRecord());

    const persisted = store.list();
    expect(persisted).toHaveLength(1);

    const fetched = persisted[0]!;
    expect(fetched).toEqual(recorded);
    // The issue's core proof: the selected referent round-trips exactly.
    expect(fetched.referent).toEqual({ id: "ref-1", source: "gesture", confidence: 0.82 });
    // And the surface metadata captured at selection time is intact.
    expect(fetched.surface).toEqual({
      id: "surface-1",
      title: "issue #23 — GitHub",
      app: "Google Chrome",
      pid: 4210,
      windowId: 71,
      availability: "available",
      accessStatus: "accessible",
    });
    expect(fetched.selectedAt).toBe("2026-06-20T12:00:00.000Z");
  });

  it("links records to the session and action that used them", () => {
    const store = createSelectionAuditStore();
    store.record(
      makeRecord({
        referent: { id: "a", source: "gesture", confidence: 0.9 },
        sessionId: "s1",
        actionId: "act-1",
      }),
    );
    store.record(
      makeRecord({
        referent: { id: "b", source: "gaze", confidence: 0.7 },
        sessionId: "s1",
        actionId: "act-2",
      }),
    );
    store.record(
      makeRecord({
        referent: { id: "c", source: "fusion", confidence: 0.6 },
        sessionId: "s2",
        actionId: "act-3",
      }),
    );

    expect(store.forSession("s1").map((entry) => entry.referent.id)).toEqual(["a", "b"]);
    expect(store.forAction("act-2").map((entry) => entry.referent.id)).toEqual(["b"]);
    expect(store.forSession("s2")).toHaveLength(1);
    expect(store.forSession("missing")).toEqual([]);
  });

  it("keeps records in insertion order", () => {
    const store = createSelectionAuditStore();
    store.record(makeRecord({ referent: { id: "first", source: "gesture", confidence: 0.5 } }));
    store.record(makeRecord({ referent: { id: "second", source: "gaze", confidence: 0.5 } }));

    expect(store.list().map((entry) => entry.referent.id)).toEqual(["first", "second"]);
  });

  it("records a selection made before an action is assigned", () => {
    const store = createSelectionAuditStore();
    store.record(makeRecord({ actionId: undefined }));

    expect(store.list()).toHaveLength(1);
    expect(store.forAction("action-1")).toHaveLength(0);
  });

  it("rejects an invalid record at the boundary and does not persist it", () => {
    const store = createSelectionAuditStore();

    expect(() =>
      store.record(makeRecord({ referent: { id: "x", source: "gesture", confidence: 5 } })),
    ).toThrow(/invalid surface selection record/i);
    expect(store.list()).toHaveLength(0);
  });

  it("does not mutate the internal log when a returned list is changed", () => {
    const store = createSelectionAuditStore();
    store.record(makeRecord());

    const snapshot = store.list();
    (snapshot as SurfaceSelectionRecord[]).push(makeRecord({ sessionId: "leak" }));

    expect(store.list()).toHaveLength(1);
  });
});
