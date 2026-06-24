import { safeParseCuaActionResult } from "@handsoff/contracts";
import type {
  ActionTarget,
  CuaActionResult,
  CuaApp,
  CuaPermissionReport,
  CuaResult,
  CuaScreenshot,
  CuaWindow,
  CuaWindowState,
  DriverToolDefinition,
} from "@handsoff/contracts";

export type CuaDriver = {
  checkPermissions(): Promise<CuaResult<CuaPermissionReport>>;
  listApps(): Promise<CuaResult<readonly CuaApp[]>>;
  listWindows(): Promise<CuaResult<readonly CuaWindow[]>>;
  launchApp(app: { appName: string; bundleId?: string }): Promise<CuaActionResult>;
  getWindowState(target: ActionTarget): Promise<CuaResult<CuaWindowState>>;
  click(target: ActionTarget): Promise<CuaActionResult>;
  typeText(target: ActionTarget, text: string): Promise<CuaActionResult>;
  setValue(target: ActionTarget, value: string): Promise<CuaActionResult>;
  screenshot(target: ActionTarget): Promise<CuaResult<CuaScreenshot>>;
  // Generic passthrough to the full driver tool surface. `call` runs any tool by
  // name with its raw JSON input and returns the driver's result; `listTools`
  // returns the driver's self-described catalog (the agent's function set).
  call(tool: string, input: unknown): Promise<CuaResult<unknown>>;
  listTools(): Promise<CuaResult<readonly DriverToolDefinition[]>>;
};

export function cuaSucceeded<T>(value: T): CuaResult<T> {
  return { status: "succeeded", value };
}

export function cuaFailed(error: string): CuaResult<never> {
  return { status: "failed", error };
}

export function cuaBlocked(reason: string): CuaResult<never> {
  return { status: "blocked", reason };
}

export function normalizeCuaActionResult(input: unknown): CuaActionResult {
  const parsed = safeParseCuaActionResult(input);
  if (parsed.success) {
    return parsed.data;
  }
  return { status: "failed", error: `Invalid CUA result: ${parsed.error.message}` };
}

export function cuaResultToActionResult<T>(
  result: CuaResult<T>,
  summary: string,
  state?: (value: T) => CuaActionResult["state"],
): CuaActionResult {
  if (result.status === "failed") return { status: "failed", error: result.error };
  if (result.status === "blocked") return { status: "blocked", reason: result.reason };
  const capturedState = state?.(result.value);
  return {
    status: "succeeded",
    summary,
    ...(capturedState ? { state: capturedState } : {}),
  };
}

export function createUnavailableCuaDriver(reason = "cua-driver is unavailable"): CuaDriver {
  const blocked = async (): Promise<CuaActionResult> => ({ status: "blocked", reason });
  const blockedResult = async (): Promise<CuaResult<never>> => cuaBlocked(reason);

  return {
    async checkPermissions() {
      return cuaSucceeded({
        accessibility: "unknown",
        screenRecording: "unknown",
        driver: "unavailable",
      });
    },
    listApps: blockedResult,
    listWindows: blockedResult,
    launchApp: blocked,
    getWindowState: blockedResult,
    click: blocked,
    typeText: blocked,
    setValue: blocked,
    screenshot: blockedResult,
    call: blockedResult,
    listTools: blockedResult,
  };
}
