import type {
  SelectedReferent,
  SurfaceSelectionRecord,
  SurfaceSnapshot,
} from "@handsoff/contracts";

// Shared fakes for the surface-selection audit fixtures (#23): a surface
// snapshot, the referent that resolved to it, and the audit record that joins
// them. Any lane testing against these contracts builds from here instead of
// re-declaring the literal. Each builder takes partial overrides so a test
// states only the fields it cares about.

export function fakeSurfaceSnapshot(overrides: Partial<SurfaceSnapshot> = {}): SurfaceSnapshot {
  return {
    id: "surface-1",
    title: "issue #23 — GitHub",
    app: "Google Chrome",
    pid: 4210,
    windowId: 71,
    availability: "available",
    accessStatus: "accessible",
    ...overrides,
  };
}

export function fakeSelectedReferent(overrides: Partial<SelectedReferent> = {}): SelectedReferent {
  return {
    id: "ref-1",
    source: "gesture",
    confidence: 0.82,
    ...overrides,
  };
}

export function fakeSelectionRecord(
  overrides: Partial<SurfaceSelectionRecord> = {},
): SurfaceSelectionRecord {
  return {
    referent: fakeSelectedReferent(),
    surface: fakeSurfaceSnapshot(),
    sessionId: "session-1",
    actionId: "action-1",
    selectedAt: "2026-06-20T12:00:00.000Z",
    ...overrides,
  };
}
