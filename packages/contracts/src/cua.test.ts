import { describe, expect, it } from "vitest";

import { safeParseCuaActionResult } from "./cua";
import type { CuaActionResult, CuaWindowState } from "./cua";

function state(): CuaWindowState {
  return {
    surface: {
      id: "surface-1",
      title: "Notes",
      app: "Notes",
      pid: 42,
      windowId: 7,
      availability: "available",
      accessStatus: "accessible",
    },
    capturedAt: "2026-06-22T12:00:00.000Z",
    elements: [{ id: "element-1", index: 0, role: "button", label: "Save" }],
  };
}

describe("CUA contract", () => {
  it("accepts a successful action result with concrete returned state", () => {
    const result = safeParseCuaActionResult({
      status: "succeeded",
      summary: "Clicked Save",
      state: state(),
    } satisfies CuaActionResult);

    expect(result.success).toBe(true);
  });

  it("accepts blocked results so permission failures do not become actions", () => {
    const result = safeParseCuaActionResult({
      status: "blocked",
      reason: "Accessibility permission denied",
      state: state(),
    } satisfies CuaActionResult);

    expect(result.success).toBe(true);
  });

  it("rejects unknown result statuses", () => {
    const result = safeParseCuaActionResult({
      status: "waiting",
      summary: "not a contract status",
    });

    expect(result.success).toBe(false);
  });
});
