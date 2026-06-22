import type {
  ActionTarget,
  CuaActionResult,
  CuaApp,
  CuaPermissionReport,
  CuaWindow,
  CuaWindowState,
} from "@handsoff/contracts";

import type { CuaDriver } from "./driver";
import { normalizeCuaActionResult } from "./driver";

export type CuaInvoke = <T>(command: string, args?: Record<string, unknown>) => Promise<T>;

type HostWindowState = Omit<CuaWindowState, "capturedAt">;
type ResolvedActionTarget = ActionTarget & {
  surface: ActionTarget["surface"] & { pid: number; windowId: number };
};

function isUsableWindow(window: CuaWindow): boolean {
  return (
    window.availability === "available" &&
    window.accessStatus === "accessible" &&
    !window.app.toLowerCase().includes("cua driver")
  );
}

export function createTauriCuaDriver(invoke: CuaInvoke): CuaDriver {
  async function listWindows(): Promise<readonly CuaWindow[]> {
    return invoke<CuaWindow[]>("cua_list_windows");
  }

  async function resolve(target: ActionTarget): Promise<ActionTarget | null> {
    if (target.surface.pid !== undefined && target.surface.windowId !== undefined) {
      return target;
    }
    const windows = await listWindows();
    const window =
      windows.find((candidate) => isUsableWindow(candidate) && candidate.focused) ??
      windows.find(isUsableWindow);
    return window ? { ...target, surface: window } : null;
  }

  async function withResolvedTarget(
    target: ActionTarget,
    run: (target: ResolvedActionTarget) => Promise<CuaActionResult>,
  ): Promise<CuaActionResult> {
    const resolved = await resolve(target);
    if (
      !resolved ||
      resolved.surface.pid === undefined ||
      resolved.surface.windowId === undefined
    ) {
      return { status: "blocked", reason: "No accessible CUA window was found" };
    }
    try {
      return await run(resolved as ResolvedActionTarget);
    } catch (caught) {
      return { status: "failed", error: caught instanceof Error ? caught.message : String(caught) };
    }
  }

  async function getWindowState(target: ActionTarget) {
    return withResolvedTarget(target, async (resolved) => {
      const state = await invoke<HostWindowState>("cua_get_window_state", {
        pid: resolved.surface.pid,
        windowId: resolved.surface.windowId,
      });
      return {
        status: "succeeded",
        summary: "Window state captured",
        state: { ...state, capturedAt: new Date().toISOString() },
      };
    });
  }

  return {
    async checkPermissions(): Promise<CuaPermissionReport> {
      return invoke<CuaPermissionReport>("cua_permissions");
    },
    async listApps(): Promise<readonly CuaApp[]> {
      return [];
    },
    listWindows,
    getWindowState,
    async click(target) {
      return withResolvedTarget(target, (resolved) =>
        invoke("cua_click", {
          pid: resolved.surface.pid,
          windowId: resolved.surface.windowId,
          elementIndex: resolved.elementIndex ?? 0,
        }).then(normalizeCuaActionResult),
      );
    },
    async typeText(target, text) {
      return withResolvedTarget(target, (resolved) =>
        invoke("cua_type_text", {
          pid: resolved.surface.pid,
          windowId: resolved.surface.windowId,
          elementIndex: resolved.elementIndex ?? 0,
          text,
        }).then(normalizeCuaActionResult),
      );
    },
    async setValue(target, value) {
      return withResolvedTarget(target, (resolved) =>
        invoke("cua_set_value", {
          pid: resolved.surface.pid,
          windowId: resolved.surface.windowId,
          elementIndex: resolved.elementIndex ?? 0,
          value,
        }).then(normalizeCuaActionResult),
      );
    },
    screenshot: getWindowState,
  };
}
