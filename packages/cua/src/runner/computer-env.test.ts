import { describe, expect, it, vi } from "vitest";

import { computerActionToDriverCall, createTauriComputerEnv } from "./computer-env";

describe("computerActionToDriverCall", () => {
  it("maps a screenshot to a screenshot-returning driver call", () => {
    expect(computerActionToDriverCall({ action: "screenshot" })).toEqual({
      kind: "invoke",
      command: "cua_screenshot",
      args: {},
      expectsScreenshot: true,
    });
  });

  it("maps a left_click to a left single-click at the coordinate", () => {
    expect(computerActionToDriverCall({ action: "left_click", coordinate: [12, 34] })).toEqual({
      kind: "invoke",
      command: "cua_pointer_click",
      args: { button: "left", clicks: 1, x: 12, y: 34 },
      expectsScreenshot: false,
    });
  });

  it("carries a modifier key through on a click", () => {
    const call = computerActionToDriverCall({
      action: "left_click",
      coordinate: [1, 2],
      text: "shift",
    });
    expect(call).toMatchObject({ args: { modifier: "shift" } });
  });

  it("maps double and right clicks to button + click count", () => {
    expect(
      computerActionToDriverCall({ action: "double_click", coordinate: [1, 2] }),
    ).toMatchObject({ command: "cua_pointer_click", args: { button: "left", clicks: 2 } });
    expect(computerActionToDriverCall({ action: "right_click", coordinate: [1, 2] })).toMatchObject(
      {
        args: { button: "right", clicks: 1 },
      },
    );
  });

  it("maps type and key", () => {
    expect(computerActionToDriverCall({ action: "type", text: "hi" })).toMatchObject({
      command: "cua_type",
      args: { text: "hi" },
    });
    expect(computerActionToDriverCall({ action: "key", text: "ctrl+s" })).toMatchObject({
      command: "cua_key",
      args: { keys: "ctrl+s" },
    });
  });

  it("maps scroll with direction and amount", () => {
    expect(
      computerActionToDriverCall({
        action: "scroll",
        coordinate: [5, 6],
        scroll_direction: "down",
        scroll_amount: 3,
      }),
    ).toMatchObject({
      command: "cua_scroll",
      args: { x: 5, y: 6, direction: "down", amount: 3 },
    });
  });

  it("converts hold_key duration (seconds) to milliseconds", () => {
    expect(
      computerActionToDriverCall({ action: "hold_key", text: "a", duration: 2 }),
    ).toMatchObject({ command: "cua_hold_key", args: { keys: "a", durationMs: 2000 } });
  });

  it("maps wait to a delay with no driver call", () => {
    expect(computerActionToDriverCall({ action: "wait", duration: 1.5 })).toEqual({
      kind: "wait",
      ms: 1500,
    });
  });

  it("maps zoom to a region screenshot", () => {
    expect(computerActionToDriverCall({ action: "zoom", region: [0, 0, 10, 20] })).toMatchObject({
      command: "cua_screenshot",
      args: { region: [0, 0, 10, 20] },
      expectsScreenshot: true,
    });
  });
});

describe("createTauriComputerEnv", () => {
  it("returns the screenshot string from a screenshot action", async () => {
    const invoke = vi.fn().mockResolvedValue("BASE64IMG");
    const env = createTauriComputerEnv({ invoke });
    const outcome = await env.execute({ action: "screenshot" });
    expect(outcome).toEqual({ status: "ok", screenshot: "BASE64IMG" });
    expect(invoke).toHaveBeenCalledWith("cua_screenshot", {});
  });

  it("returns ok (no screenshot) for a click and forwards the command", async () => {
    const invoke = vi.fn().mockResolvedValue(undefined);
    const env = createTauriComputerEnv({ invoke });
    const outcome = await env.execute({ action: "left_click", coordinate: [3, 4] });
    expect(outcome).toEqual({ status: "ok" });
    expect(invoke).toHaveBeenCalledWith("cua_pointer_click", {
      button: "left",
      clicks: 1,
      x: 3,
      y: 4,
    });
  });

  it("delays without invoking the driver on a wait action", async () => {
    const invoke = vi.fn();
    const wait = vi.fn().mockResolvedValue(undefined);
    const env = createTauriComputerEnv({ invoke, wait });
    const outcome = await env.execute({ action: "wait", duration: 2 });
    expect(outcome).toEqual({ status: "ok" });
    expect(wait).toHaveBeenCalledWith(2000);
    expect(invoke).not.toHaveBeenCalled();
  });

  it("reports an error outcome when the driver call throws", async () => {
    const invoke = vi.fn().mockRejectedValue(new Error("cua-driver unavailable"));
    const env = createTauriComputerEnv({ invoke });
    const outcome = await env.execute({ action: "left_click", coordinate: [1, 1] });
    expect(outcome).toEqual({ status: "error", error: "cua-driver unavailable" });
  });
});
