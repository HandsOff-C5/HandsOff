import { describe, expect, it } from "vitest";

import { createFakeCuaDriver } from "./fake-driver";
import { createUnavailableCuaDriver, normalizeCuaActionResult } from "./driver";
import type { CuaWindowState } from "@handsoff/contracts";

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
    elements: [{ id: "button-1", index: 0, role: "button", label: "Save" }],
  };
}

describe("CUA driver boundary", () => {
  it("normalizes valid action results", () => {
    expect(normalizeCuaActionResult({ status: "succeeded", summary: "Clicked" })).toEqual({
      status: "succeeded",
      summary: "Clicked",
    });
  });

  it("turns invalid raw payloads into failed results", () => {
    expect(normalizeCuaActionResult({ ok: true })).toMatchObject({ status: "failed" });
  });

  it("returns blocked results when the driver is unavailable", async () => {
    const driver = createUnavailableCuaDriver("driver missing");
    const result = await driver.click({ surface: state().surface });

    expect(result).toEqual({ status: "blocked", reason: "driver missing" });
  });

  it("records fake CUA calls and returns concrete window state", async () => {
    const driver = createFakeCuaDriver({ state: state() });
    const target = { surface: state().surface, elementIndex: 0 };

    await driver.getWindowState(target);
    const result = await driver.click(target);

    expect(result).toMatchObject({ status: "succeeded", state: state() });
    expect(driver.calls().map((call) => call.kind)).toEqual(["get_window_state", "click"]);
  });

  it("blocks fake mutating actions when Accessibility is denied", async () => {
    const driver = createFakeCuaDriver({
      state: state(),
      permissions: {
        accessibility: "denied",
        screenRecording: "granted",
        driver: "running",
      },
    });

    const result = await driver.typeText({ surface: state().surface }, "hello");

    expect(result).toMatchObject({
      status: "blocked",
      reason: "Accessibility permission denied",
    });
  });
});
