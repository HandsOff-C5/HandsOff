import {
  cuaPermissionReportSchema,
  cuaWindowSchema,
  safeParseCuaWindowState,
  type ActionTarget,
  type CuaActionResult,
  type CuaApp,
  type CuaPermissionReport,
  type CuaWindow,
} from "@handsoff/contracts";
import type { CuaWindowState } from "@handsoff/contracts";

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

function isResolvedTarget(target: ActionTarget | null): target is ResolvedActionTarget {
  return target?.surface.pid !== undefined && target.surface.windowId !== undefined;
}

function targetAppName(target: ActionTarget): string | null {
  const app = target.surface.app.trim();
  return app && app !== "Current app" ? app.toLowerCase() : null;
}

function parsePermissions(input: unknown): CuaPermissionReport {
  const parsed = cuaPermissionReportSchema.safeParse(input);
  return parsed.success
    ? parsed.data
    : { accessibility: "unknown", screenRecording: "unknown", driver: "unknown" };
}

function parseWindows(input: unknown): readonly CuaWindow[] {
  const parsed = cuaWindowSchema.array().safeParse(input);
  return parsed.success ? parsed.data : [];
}

function withCapturedAt(input: unknown): unknown {
  if (!input || typeof input !== "object" || Array.isArray(input)) return input;
  return { ...input, capturedAt: new Date().toISOString() };
}

export function createTauriCuaDriver(invoke: CuaInvoke): CuaDriver {
  async function listWindows(): Promise<readonly CuaWindow[]> {
    return parseWindows(await invoke("cua_list_windows"));
  }

  async function resolve(target: ActionTarget): Promise<ActionTarget | null> {
    if (target.surface.pid !== undefined && target.surface.windowId !== undefined) {
      return target;
    }
    const windows = await listWindows();
    const appName = targetAppName(target);
    const namedWindow = appName
      ? windows.find(
          (candidate) => isUsableWindow(candidate) && candidate.app.toLowerCase() === appName,
        )
      : undefined;
    const window =
      namedWindow ??
      windows.find((candidate) => isUsableWindow(candidate) && candidate.focused) ??
      windows.find(isUsableWindow);
    return window ? { ...target, surface: window } : null;
  }

  async function withResolvedTarget(
    target: ActionTarget,
    run: (target: ResolvedActionTarget) => Promise<CuaActionResult>,
  ): Promise<CuaActionResult> {
    const resolved = await resolve(target);
    if (!isResolvedTarget(resolved)) {
      return { status: "blocked", reason: "No accessible CUA window was found" };
    }
    try {
      return await run(resolved);
    } catch (caught) {
      return { status: "failed", error: caught instanceof Error ? caught.message : String(caught) };
    }
  }

  async function getWindowState(target: ActionTarget) {
    return withResolvedTarget(target, async (resolved) => {
      const parsed = safeParseCuaWindowState(
        withCapturedAt(
          await invoke<HostWindowState>("cua_get_window_state", {
            pid: resolved.surface.pid,
            windowId: resolved.surface.windowId,
          }),
        ),
      );
      if (!parsed.success) {
        return { status: "failed", error: `Invalid CUA window state: ${parsed.error.message}` };
      }
      return {
        status: "succeeded",
        summary: "Window state captured",
        state: parsed.data,
      };
    });
  }

  return {
    async checkPermissions(): Promise<CuaPermissionReport> {
      return parsePermissions(await invoke("cua_permissions"));
    },
    async listApps(): Promise<readonly CuaApp[]> {
      return [];
    },
    listWindows,
    async launchApp({ appName, bundleId }) {
      return normalizeCuaActionResult(
        await invoke("cua_launch_app", { appName, ...(bundleId && { bundleId }) }),
      );
    },
    getWindowState,
    async click(target) {
      return withResolvedTarget(target, (resolved) => {
        const params: Record<string, unknown> = {
          pid: resolved.surface.pid,
          windowId: resolved.surface.windowId,
        };
        if (resolved.elementIndex !== undefined) params.elementIndex = resolved.elementIndex;
        return invoke("cua_click", params).then(normalizeCuaActionResult);
      });
    },
    async typeText(target, text) {
      return withResolvedTarget(target, (resolved) => {
        const params: Record<string, unknown> = {
          pid: resolved.surface.pid,
          windowId: resolved.surface.windowId,
          text,
        };
        if (resolved.elementIndex !== undefined) params.elementIndex = resolved.elementIndex;
        return invoke("cua_type_text", params).then(normalizeCuaActionResult);
      });
    },
    async setValue(target, value) {
      return withResolvedTarget(target, (resolved) => {
        const params: Record<string, unknown> = {
          pid: resolved.surface.pid,
          windowId: resolved.surface.windowId,
          value,
        };
        if (resolved.elementIndex !== undefined) params.elementIndex = resolved.elementIndex;
        return invoke("cua_set_value", params).then(normalizeCuaActionResult);
      });
    },
    screenshot: getWindowState,
  };
}
