import { safeParseCuaActionResult } from "@handsoff/contracts";
import type {
  ActionTarget,
  CuaActionResult,
  CuaApp,
  CuaPermissionReport,
  CuaWindow,
} from "@handsoff/contracts";

export type CuaDriver = {
  checkPermissions(): Promise<CuaPermissionReport>;
  listApps(): Promise<readonly CuaApp[]>;
  listWindows(): Promise<readonly CuaWindow[]>;
  getWindowState(target: ActionTarget): Promise<CuaActionResult>;
  click(target: ActionTarget): Promise<CuaActionResult>;
  typeText(target: ActionTarget, text: string): Promise<CuaActionResult>;
  setValue(target: ActionTarget, value: string): Promise<CuaActionResult>;
  screenshot(target: ActionTarget): Promise<CuaActionResult>;
};

export function normalizeCuaActionResult(input: unknown): CuaActionResult {
  const parsed = safeParseCuaActionResult(input);
  if (parsed.success) {
    return parsed.data;
  }
  return { status: "failed", error: `Invalid CUA result: ${parsed.error.message}` };
}

export function createUnavailableCuaDriver(reason = "cua-driver is unavailable"): CuaDriver {
  const blocked = async (): Promise<CuaActionResult> => ({ status: "blocked", reason });

  return {
    async checkPermissions() {
      return { accessibility: "unknown", screenRecording: "unknown", driver: "unavailable" };
    },
    async listApps() {
      return [];
    },
    async listWindows() {
      return [];
    },
    getWindowState: blocked,
    click: blocked,
    typeText: blocked,
    setValue: blocked,
    screenshot: blocked,
  };
}
