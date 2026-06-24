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
    await expect(driver.listWindows()).resolves.toEqual({
      status: "blocked",
      reason: "driver missing",
    });
  });

  it("records fake CUA calls and returns concrete window state", async () => {
    const driver = createFakeCuaDriver({ state: state() });
    const target = { surface: state().surface, elementIndex: 0 };

    const stateResult = await driver.getWindowState(target);
    const result = await driver.click(target);

    expect(stateResult).toMatchObject({ status: "succeeded", value: state() });
    expect(result).toMatchObject({ status: "succeeded", state: state() });
    expect(driver.calls().map((call) => call.kind)).toEqual(["get_window_state", "click"]);
  });

  it("returns typed health results for fake permissions, apps, and windows", async () => {
    const driver = createFakeCuaDriver({
      state: state(),
      apps: [{ id: "com.apple.Notes", name: "Notes", pid: 42, bundleId: "com.apple.Notes" }],
      windows: [state().surface],
    });

    await expect(driver.checkPermissions()).resolves.toEqual({
      status: "succeeded",
      value: { accessibility: "granted", screenRecording: "granted", driver: "running" },
    });
    await expect(driver.listApps()).resolves.toEqual({
      status: "succeeded",
      value: [{ id: "com.apple.Notes", name: "Notes", pid: 42, bundleId: "com.apple.Notes" }],
    });
    await expect(driver.listWindows()).resolves.toEqual({
      status: "succeeded",
      value: [state().surface],
    });
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
    await expect(driver.getWindowState({ surface: state().surface })).resolves.toMatchObject({
      status: "blocked",
      reason: "Accessibility permission denied",
    });
  });

  it("blocks fake state capture when the target window is unavailable", async () => {
    const driver = createFakeCuaDriver({ state: state(), windows: [] });

    await expect(driver.getWindowState({ surface: state().surface })).resolves.toEqual({
      status: "blocked",
      reason: "Target window is unavailable",
    });
  });
});
