import { describe, expect, it } from "vitest";

import {
  cuaActionRequestSchema,
  cuaAppSchema,
  cuaScreenshotSchema,
  safeParseCuaActionResult,
  safeParseCuaWindowState,
} from "./cua";
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
    elementCount: 1,
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

  it("keeps driver element count separate from parsed elements", () => {
    const result = safeParseCuaWindowState({
      surface: state().surface,
      capturedAt: "2026-06-22T12:00:00.000Z",
      elementCount: 3,
    });

    expect(result.success && result.data).toMatchObject({
      elementCount: 3,
      elements: [],
    });
  });

  it("accepts app-launch action requests", () => {
    const result = cuaActionRequestSchema.safeParse({
      kind: "launch_app",
      appName: "TextEdit",
    });

    expect(result.success).toBe(true);
  });

  it("accepts normalized app inventory records", () => {
    const result = cuaAppSchema.safeParse({
      id: "com.apple.Notes",
      name: "Notes",
      pid: 42,
      bundleId: "com.apple.Notes",
      running: true,
      active: false,
    });

    expect(result.success).toBe(true);
  });

  it("accepts typed screenshot metadata from the CUA adapter", () => {
    const result = cuaScreenshotSchema.safeParse({
      surface: state().surface,
      capturedAt: "2026-06-22T12:00:00.000Z",
      mimeType: "image/png",
      width: 640,
      height: 480,
      pngBase64: "abc123",
    });

    expect(result.success).toBe(true);
  });
});
