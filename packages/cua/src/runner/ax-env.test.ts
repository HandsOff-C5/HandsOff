import { describe, expect, it, vi } from "vitest";

import { cuaAgentActionToDriverCall, createTauriCuaAgentEnv, summarizeWindowState } from "./ax-env";

const target = { pid: 85545, windowId: 5833 };

describe("cuaAgentActionToDriverCall — action → cua_* driver command", () => {
  it("maps a snapshot to cua_get_window_state and marks it state-bearing", () => {
    expect(cuaAgentActionToDriverCall({ kind: "snapshot" }, target)).toEqual({
      command: "cua_get_window_state",
      args: { pid: 85545, windowId: 5833 },
      expectsState: true,
    });
  });

  it("maps an element-index click into cua_click on the active window", () => {
    expect(cuaAgentActionToDriverCall({ kind: "click", elementIndex: 16 }, target)).toEqual({
      command: "cua_click",
      args: { pid: 85545, windowId: 5833, elementIndex: 16 },
      expectsState: false,
    });
  });

  it("maps a pixel fallback click with its optional button", () => {
    expect(
      cuaAgentActionToDriverCall({ kind: "click_point", x: 12, y: 34, button: "right" }, target),
    ).toEqual({
      command: "cua_click_point",
      args: { pid: 85545, windowId: 5833, x: 12, y: 34, button: "right" },
      expectsState: false,
    });
  });

  it("maps type_text, set_value, press_key (with modifiers), hotkey, and scroll", () => {
    expect(
      cuaAgentActionToDriverCall({ kind: "type_text", elementIndex: 3, text: "hi" }, target).args,
    ).toEqual({ pid: 85545, windowId: 5833, elementIndex: 3, text: "hi" });
    expect(
      cuaAgentActionToDriverCall({ kind: "set_value", elementIndex: 3, value: "x" }, target).args,
    ).toEqual({ pid: 85545, windowId: 5833, elementIndex: 3, value: "x" });
    expect(
      cuaAgentActionToDriverCall(
        { kind: "press_key", key: "a", modifiers: ["cmd"], elementIndex: 5 },
        target,
      ).args,
    ).toEqual({ pid: 85545, windowId: 5833, key: "a", modifiers: ["cmd"], elementIndex: 5 });
    expect(cuaAgentActionToDriverCall({ kind: "hotkey", keys: ["cmd", "c"] }, target).args).toEqual(
      {
        pid: 85545,
        windowId: 5833,
        keys: ["cmd", "c"],
      },
    );
    expect(
      cuaAgentActionToDriverCall({ kind: "scroll", direction: "down", by: "page" }, target).args,
    ).toEqual({ pid: 85545, windowId: 5833, direction: "down", by: "page" });
  });

  it("maps launch_app without the window target", () => {
    expect(cuaAgentActionToDriverCall({ kind: "launch_app", appName: "Cursor" }, target)).toEqual({
      command: "cua_launch_app",
      args: { appName: "Cursor" },
      expectsState: false,
    });
  });
});

describe("summarizeWindowState — element list for the model", () => {
  it('renders one [index] role "label" line per element', () => {
    const text = summarizeWindowState({
      surface: {
        id: "1",
        title: "Calc",
        app: "Calculator",
        availability: "available",
        accessStatus: "accessible",
      },
      capturedAt: "2026-06-22T12:00:00.000Z",
      elementCount: 2,
      elements: [
        { id: "a", index: 7, role: "AXButton", label: "7" },
        { id: "b", index: 16, role: "AXButton", label: "Equals" },
      ],
    });
    expect(text).toContain('[7] AXButton "7"');
    expect(text).toContain('[16] AXButton "Equals"');
  });
});

describe("createTauriCuaAgentEnv — drives the driver and refreshes state", () => {
  const state = {
    surface: {
      id: "1",
      title: "Calc",
      app: "Calculator",
      availability: "available",
      accessStatus: "accessible",
    },
    capturedAt: "2026-06-22T12:00:00.000Z",
    elementCount: 1,
    elements: [{ id: "a", index: 16, role: "AXButton", label: "Equals" }],
    screenshot: { pngBase64: "PNG", mimeType: "image/png", width: 230, height: 408 },
  };

  it("returns the screenshot + element text for a snapshot", async () => {
    const invoke = vi.fn().mockResolvedValue(state);
    const env = createTauriCuaAgentEnv({ invoke, target });
    const outcome = await env.execute({ kind: "snapshot" });
    expect(invoke).toHaveBeenCalledWith("cua_get_window_state", { pid: 85545, windowId: 5833 });
    expect(outcome).toMatchObject({ status: "ok", screenshot: "PNG" });
    expect(outcome.status === "ok" && outcome.text).toContain('[16] AXButton "Equals"');
  });

  it("after a mutating action, auto-refreshes so the model sees the result", async () => {
    const invoke = vi
      .fn()
      .mockResolvedValueOnce(undefined) // the click
      .mockResolvedValueOnce(state); // the auto-refresh snapshot
    const env = createTauriCuaAgentEnv({ invoke, target });
    const outcome = await env.execute({ kind: "click", elementIndex: 16 });
    expect(invoke).toHaveBeenNthCalledWith(1, "cua_click", {
      pid: 85545,
      windowId: 5833,
      elementIndex: 16,
    });
    expect(invoke).toHaveBeenNthCalledWith(2, "cua_get_window_state", {
      pid: 85545,
      windowId: 5833,
    });
    expect(outcome).toMatchObject({ status: "ok", screenshot: "PNG" });
  });

  it("feeds a driver error back as an error outcome instead of throwing", async () => {
    const invoke = vi.fn().mockRejectedValue(new Error("stale element"));
    const env = createTauriCuaAgentEnv({ invoke, target });
    const outcome = await env.execute({ kind: "click", elementIndex: 99 });
    expect(outcome).toEqual({ status: "error", error: "stale element" });
  });
});
