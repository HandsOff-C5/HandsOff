import type { CuaWindow, CuaWindowState } from "@handsoff/contracts";
import { describe, expect, it } from "vitest";

import { createTauriCuaDriver, type CuaInvoke } from "./tauri-driver";

const driverWindow: CuaWindow = {
  id: "driver:1",
  title: "Cua Driver",
  app: "Cua Driver",
  pid: 1,
  windowId: 10,
  availability: "available",
  accessStatus: "accessible",
  focused: true,
};

const workWindow: CuaWindow = {
  id: "notes:2",
  title: "Notes",
  app: "Notes",
  pid: 2,
  windowId: 20,
  availability: "available",
  accessStatus: "accessible",
};

const focusedWorkWindow: CuaWindow = {
  id: "mail:3",
  title: "Inbox",
  app: "Mail",
  pid: 3,
  windowId: 30,
  availability: "available",
  accessStatus: "accessible",
  focused: true,
};

const unresolvedTarget = {
  surface: {
    id: "active-window",
    title: "Active window",
    app: "Current app",
    availability: "available" as const,
    accessStatus: "accessible" as const,
  },
  elementIndex: 2,
};

describe("Tauri CUA driver", () => {
  it("resolves an implicit target to the first usable non-driver window", async () => {
    const calls: Array<{ command: string; args?: Record<string, unknown> }> = [];
    const invoke: CuaInvoke = async <T>(command: string, args?: Record<string, unknown>) => {
      calls.push({ command, args });
      if (command === "cua_list_windows") return [driverWindow, workWindow] as T;
      if (command === "cua_click") return { status: "succeeded", summary: "Clicked" } as T;
      throw new Error(`Unexpected command: ${command}`);
    };

    const result = await createTauriCuaDriver(invoke).click(unresolvedTarget);

    expect(result).toEqual({ status: "succeeded", summary: "Clicked" });
    expect(calls).toEqual([
      { command: "cua_list_windows", args: undefined },
      {
        command: "cua_click",
        args: { pid: 2, windowId: 20, elementIndex: 2 },
      },
    ]);
  });

  it("captures state with the resolved target surface", async () => {
    const invoke: CuaInvoke = async <T>(command: string) => {
      if (command === "cua_list_windows") return [workWindow] as T;
      if (command === "cua_get_window_state") {
        return { surface: workWindow, elements: [] } as Omit<CuaWindowState, "capturedAt"> as T;
      }
      throw new Error(`Unexpected command: ${command}`);
    };

    const result = await createTauriCuaDriver(invoke).getWindowState(unresolvedTarget);

    expect(result).toMatchObject({
      status: "succeeded",
      state: { surface: workWindow, elements: [] },
    });
  });

  it("prefers the focused usable window when the driver reports one", async () => {
    const calls: Array<{ command: string; args?: Record<string, unknown> }> = [];
    const invoke: CuaInvoke = async <T>(command: string, args?: Record<string, unknown>) => {
      calls.push({ command, args });
      if (command === "cua_list_windows") return [workWindow, focusedWorkWindow] as T;
      if (command === "cua_click") return { status: "succeeded", summary: "Clicked" } as T;
      throw new Error(`Unexpected command: ${command}`);
    };

    await createTauriCuaDriver(invoke).click(unresolvedTarget);

    expect(calls.at(-1)).toEqual({
      command: "cua_click",
      args: { pid: 3, windowId: 30, elementIndex: 2 },
    });
  });

  it("blocks when only CUA driver windows are available", async () => {
    const calls: string[] = [];
    const invoke: CuaInvoke = async <T>(command: string) => {
      calls.push(command);
      if (command === "cua_list_windows") return [driverWindow] as T;
      throw new Error(`Unexpected command: ${command}`);
    };

    const result = await createTauriCuaDriver(invoke).click(unresolvedTarget);

    expect(result).toEqual({ status: "blocked", reason: "No accessible CUA window was found" });
    expect(calls).toEqual(["cua_list_windows"]);
  });
});
