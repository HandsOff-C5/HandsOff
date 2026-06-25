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

const textEditTarget = {
  surface: {
    id: "app:textedit",
    title: "TextEdit",
    app: "TextEdit",
    availability: "unknown" as const,
    accessStatus: "unknown" as const,
  },
  elementIndex: 0,
};

describe("Tauri CUA driver", () => {
  it("returns typed permission and app inventory results", async () => {
    const app = {
      id: "com.apple.Notes",
      name: "Notes",
      pid: 2,
      bundleId: "com.apple.Notes",
      running: true,
      active: false,
    };
    const calls: Array<{ command: string; args?: Record<string, unknown> }> = [];
    const invoke: CuaInvoke = async <T>(command: string, args?: Record<string, unknown>) => {
      calls.push({ command, args });
      if (command === "cua_permissions") {
        return { accessibility: "granted", screenRecording: "denied", driver: "running" } as T;
      }
      if (command === "cua_list_apps") return [app] as T;
      throw new Error(`Unexpected command: ${command}`);
    };

    const driver = createTauriCuaDriver(invoke);

    await expect(driver.checkPermissions()).resolves.toEqual({
      status: "succeeded",
      value: { accessibility: "granted", screenRecording: "denied", driver: "running" },
    });
    await expect(driver.listApps()).resolves.toEqual({ status: "succeeded", value: [app] });
    expect(calls.map((call) => call.command)).toEqual(["cua_permissions", "cua_list_apps"]);
  });

  it("fails invalid native window lists instead of silently returning no windows", async () => {
    const invoke: CuaInvoke = async <T>(command: string) => {
      if (command === "cua_list_windows") return [{ bad: true }] as T;
      throw new Error(`Unexpected command: ${command}`);
    };

    await expect(createTauriCuaDriver(invoke).listWindows()).resolves.toMatchObject({
      status: "failed",
    });
  });

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
        return { surface: workWindow, elementCount: 3, elements: [] } as Omit<
          CuaWindowState,
          "capturedAt"
        > as T;
      }
      throw new Error(`Unexpected command: ${command}`);
    };

    const result = await createTauriCuaDriver(invoke).getWindowState(unresolvedTarget);

    expect(result).toMatchObject({
      status: "succeeded",
      value: { surface: workWindow, elementCount: 3, elements: [] },
    });
  });

  it("fails invalid native window state instead of trusting it", async () => {
    const invoke: CuaInvoke = async <T>(command: string) => {
      if (command === "cua_list_windows") return [workWindow] as T;
      if (command === "cua_get_window_state") return { surface: workWindow, elements: "bad" } as T;
      throw new Error(`Unexpected command: ${command}`);
    };

    const result = await createTauriCuaDriver(invoke).getWindowState(unresolvedTarget);

    expect(result).toMatchObject({ status: "failed" });
  });

  it("captures screenshots through a typed result", async () => {
    const invoke: CuaInvoke = async <T>(command: string) => {
      if (command === "cua_list_windows") return [workWindow] as T;
      if (command === "cua_screenshot") {
        return {
          surface: workWindow,
          mimeType: "image/png",
          width: 640,
          height: 480,
          pngBase64: "abc123",
        } as T;
      }
      throw new Error(`Unexpected command: ${command}`);
    };

    const result = await createTauriCuaDriver(invoke).screenshot(unresolvedTarget);

    expect(result).toMatchObject({
      status: "succeeded",
      value: {
        surface: workWindow,
        mimeType: "image/png",
        width: 640,
        height: 480,
        pngBase64: "abc123",
      },
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

  it("launches apps through the native CUA command", async () => {
    const calls: Array<{ command: string; args?: Record<string, unknown> }> = [];
    const invoke: CuaInvoke = async <T>(command: string, args?: Record<string, unknown>) => {
      calls.push({ command, args });
      if (command === "cua_launch_app") return { status: "succeeded", summary: "Launched" } as T;
      throw new Error(`Unexpected command: ${command}`);
    };

    const result = await createTauriCuaDriver(invoke).launchApp({ appName: "TextEdit" });

    expect(result).toEqual({ status: "succeeded", summary: "Launched" });
    expect(calls).toEqual([{ command: "cua_launch_app", args: { appName: "TextEdit" } }]);
  });

  it("prefers a named app window over the focused fallback", async () => {
    const textEditWindow: CuaWindow = {
      id: "textedit:4",
      title: "Untitled",
      app: "TextEdit",
      pid: 4,
      windowId: 40,
      availability: "available",
      accessStatus: "accessible",
    };
    const calls: Array<{ command: string; args?: Record<string, unknown> }> = [];
    const invoke: CuaInvoke = async <T>(command: string, args?: Record<string, unknown>) => {
      calls.push({ command, args });
      if (command === "cua_list_windows") return [focusedWorkWindow, textEditWindow] as T;
      if (command === "cua_type_text") return { status: "succeeded", summary: "Typed" } as T;
      throw new Error(`Unexpected command: ${command}`);
    };

    await createTauriCuaDriver(invoke).typeText(textEditTarget, "hello goodbye");

    expect(calls.at(-1)).toEqual({
      command: "cua_type_text",
      args: { pid: 4, windowId: 40, elementIndex: 0, text: "hello goodbye" },
    });
  });

  it("omits elementIndex when the target has none so cua-driver types into the focused element", async () => {
    const noIndexTarget = {
      surface: {
        id: "app:notes",
        title: "Notes",
        app: "Notes",
        availability: "available" as const,
        accessStatus: "accessible" as const,
      },
    };
    const calls: Array<{ command: string; args?: Record<string, unknown> }> = [];
    const invoke: CuaInvoke = async <T>(command: string, args?: Record<string, unknown>) => {
      calls.push({ command, args });
      if (command === "cua_list_windows") return [workWindow] as T;
      if (command === "cua_type_text") return { status: "succeeded", summary: "Typed" } as T;
      throw new Error(`Unexpected command: ${command}`);
    };

    await createTauriCuaDriver(invoke).typeText(noIndexTarget, "hello");

    expect(calls.at(-1)).toEqual({
      command: "cua_type_text",
      args: { pid: 2, windowId: 20, text: "hello" },
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
