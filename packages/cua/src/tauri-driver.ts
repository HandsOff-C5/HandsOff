import {
  cuaPermissionReportSchema,
  cuaAppSchema,
  cuaScreenshotSchema,
  cuaWindowSchema,
  safeParseCuaWindowState,
  type ActionTarget,
  type CuaActionResult,
  type CuaApp,
  type CuaPermissionReport,
  type CuaResult,
  type CuaScreenshot,
  type CuaWindow,
} from "@handsoff/contracts";
import type { CuaWindowState } from "@handsoff/contracts";

import type { CuaDriver } from "./driver";
import {
  cuaBlocked,
  cuaFailed,
  cuaResultToActionResult,
  cuaSucceeded,
  normalizeCuaActionResult,
} from "./driver";

export type CuaInvoke = <T>(command: string, args?: Record<string, unknown>) => Promise<T>;

type HostWindowState = Omit<CuaWindowState, "capturedAt">;
type ResolvedActionTarget = ActionTarget & {
  surface: ActionTarget["surface"] & { pid: number; windowId: number };
};

type ResolvedWindow = CuaWindow & { pid: number; windowId: number };

function isUsableWindow(window: CuaWindow): window is ResolvedWindow {
  return (
    window.pid !== undefined &&
    window.windowId !== undefined &&
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

function errorMessage(caught: unknown): string {
  return caught instanceof Error ? caught.message : String(caught);
}

function parsePermissions(input: unknown): CuaResult<CuaPermissionReport> {
  const parsed = cuaPermissionReportSchema.safeParse(input);
  return parsed.success
    ? cuaSucceeded(parsed.data)
    : cuaFailed(`Invalid CUA permission report: ${parsed.error.message}`);
}

function parseApps(input: unknown): CuaResult<readonly CuaApp[]> {
  const parsed = cuaAppSchema.array().safeParse(input);
  return parsed.success
    ? cuaSucceeded(parsed.data)
    : cuaFailed(`Invalid CUA apps: ${parsed.error.message}`);
}

function parseWindows(input: unknown): CuaResult<readonly CuaWindow[]> {
  const parsed = cuaWindowSchema.array().safeParse(input);
  return parsed.success
    ? cuaSucceeded(parsed.data)
    : cuaFailed(`Invalid CUA windows: ${parsed.error.message}`);
}

function withCapturedAt(input: unknown): unknown {
  if (!input || typeof input !== "object" || Array.isArray(input)) return input;
  return { ...input, capturedAt: new Date().toISOString() };
}

export function createTauriCuaDriver(invoke: CuaInvoke): CuaDriver {
  async function listWindows(): Promise<CuaResult<readonly CuaWindow[]>> {
    try {
      return parseWindows(await invoke("cua_list_windows"));
    } catch (caught) {
      return cuaFailed(errorMessage(caught));
    }
  }

  async function resolve(target: ActionTarget): Promise<CuaResult<ResolvedActionTarget>> {
    if (isResolvedTarget(target)) {
      return cuaSucceeded(target);
    }
    const windowsResult = await listWindows();
    if (windowsResult.status !== "succeeded") return windowsResult;
    const windows = windowsResult.value.filter(isUsableWindow);
    const appName = targetAppName(target);
    const namedWindow = appName
      ? windows.find((candidate) => candidate.app.toLowerCase() === appName)
      : undefined;
    const window = namedWindow ?? windows.find((candidate) => candidate.focused) ?? windows[0];
    return window
      ? cuaSucceeded({ ...target, surface: window })
      : cuaBlocked("No accessible CUA window was found");
  }

  async function withResolvedTarget(
    target: ActionTarget,
    run: (target: ResolvedActionTarget) => Promise<CuaActionResult>,
  ): Promise<CuaActionResult> {
    const resolved = await resolve(target);
    if (resolved.status !== "succeeded") return cuaResultToActionResult(resolved, "");
    try {
      return await run(resolved.value);
    } catch (caught) {
      return { status: "failed", error: errorMessage(caught) };
    }
  }

  async function getWindowState(target: ActionTarget): Promise<CuaResult<CuaWindowState>> {
    const resolved = await resolve(target);
    if (resolved.status !== "succeeded") return resolved;
    try {
      const parsed = safeParseCuaWindowState(
        withCapturedAt(
          await invoke<HostWindowState>("cua_get_window_state", {
            pid: resolved.value.surface.pid,
            windowId: resolved.value.surface.windowId,
          }),
        ),
      );
      if (!parsed.success) {
        return cuaFailed(`Invalid CUA window state: ${parsed.error.message}`);
      }
      return cuaSucceeded(parsed.data);
    } catch (caught) {
      return cuaFailed(errorMessage(caught));
    }
  }

  async function screenshot(target: ActionTarget): Promise<CuaResult<CuaScreenshot>> {
    const resolved = await resolve(target);
    if (resolved.status !== "succeeded") return resolved;
    try {
      const parsed = cuaScreenshotSchema.safeParse(
        withCapturedAt(
          await invoke("cua_screenshot", {
            pid: resolved.value.surface.pid,
            windowId: resolved.value.surface.windowId,
          }),
        ),
      );
      if (!parsed.success) {
        return cuaFailed(`Invalid CUA screenshot: ${parsed.error.message}`);
      }
      return cuaSucceeded(parsed.data);
    } catch (caught) {
      return cuaFailed(errorMessage(caught));
    }
  }

  return {
    async checkPermissions(): Promise<CuaResult<CuaPermissionReport>> {
      try {
        return parsePermissions(await invoke("cua_permissions"));
      } catch (caught) {
        return cuaFailed(errorMessage(caught));
      }
    },
    async listApps(): Promise<CuaResult<readonly CuaApp[]>> {
      try {
        return parseApps(await invoke("cua_list_apps"));
      } catch (caught) {
        return cuaFailed(errorMessage(caught));
      }
    },
    listWindows,
    async launchApp({ appName, bundleId }) {
      return normalizeCuaActionResult(
        await invoke("cua_launch_app", { appName, ...(bundleId && { bundleId }) }),
      );
    },
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
    screenshot,
  };
}
