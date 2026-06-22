import type { ActionTarget, CuaActionResult, CuaWindowState } from "@handsoff/contracts";

import { fakeSurfaceSnapshot } from "../fake-surfaces";

export function fakeActionTarget(overrides: Partial<ActionTarget> = {}): ActionTarget {
  return {
    surface: fakeSurfaceSnapshot(),
    elementIndex: 0,
    ...overrides,
  };
}

export function fakeCuaWindowState(overrides: Partial<CuaWindowState> = {}): CuaWindowState {
  return {
    surface: fakeSurfaceSnapshot(),
    capturedAt: "2026-06-22T12:00:00.000Z",
    elements: [{ id: "element-1", index: 0, role: "button", label: "Save" }],
    ...overrides,
  };
}

export function fakeCuaActionResult(overrides: Partial<CuaActionResult> = {}): CuaActionResult {
  return {
    status: "succeeded",
    summary: "Fake CUA action succeeded",
    state: fakeCuaWindowState(),
    ...overrides,
  } as CuaActionResult;
}
