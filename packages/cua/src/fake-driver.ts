import type {
  ActionTarget,
  CuaActionResult,
  CuaApp,
  CuaPermissionReport,
  CuaResult,
  CuaScreenshot,
  CuaWindow,
  CuaWindowState,
} from "@handsoff/contracts";

import type { CuaDriver } from "./driver";
import { cuaBlocked, cuaSucceeded } from "./driver";

export type FakeCuaCall =
  | { kind: "list_windows" }
  | { kind: "launch_app"; appName: string; bundleId?: string }
  | { kind: "get_window_state"; target: ActionTarget }
  | { kind: "click"; target: ActionTarget }
  | { kind: "type_text"; target: ActionTarget; text: string }
  | { kind: "set_value"; target: ActionTarget; value: string }
  | { kind: "screenshot"; target: ActionTarget };

export type FakeCuaDriver = CuaDriver & {
  calls(): readonly FakeCuaCall[];
};

export function createFakeCuaDriver(options: {
  permissions?: CuaPermissionReport;
  apps?: readonly CuaApp[];
  windows?: readonly CuaWindow[];
  state: CuaWindowState;
  nextActionResult?: CuaActionResult;
}): FakeCuaDriver {
  const permissions = options.permissions ?? {
    accessibility: "granted",
    screenRecording: "granted",
    driver: "running",
  };
  let calls: readonly FakeCuaCall[] = [];

  const record = (call: FakeCuaCall) => {
    calls = [...calls, call];
  };

  const result = (): CuaActionResult => {
    if (permissions.accessibility !== "granted") {
      return { status: "blocked", reason: "Accessibility permission denied", state: options.state };
    }
    return (
      options.nextActionResult ?? {
        status: "succeeded",
        summary: "Fake CUA action succeeded",
        state: options.state,
      }
    );
  };
  const accessibilityDenied = "Accessibility permission denied";
  const windowAvailable = (target: ActionTarget): boolean => {
    if (target.surface.pid === undefined || target.surface.windowId === undefined) return true;
    const windows = options.windows ?? [options.state.surface];
    return windows.some(
      (window) =>
        window.pid === target.surface.pid &&
        window.windowId === target.surface.windowId &&
        window.availability === "available",
    );
  };
  const stateResult = (target: ActionTarget): CuaResult<CuaWindowState> => {
    if (permissions.accessibility !== "granted") return cuaBlocked(accessibilityDenied);
    if (!windowAvailable(target)) return cuaBlocked("Target window is unavailable");
    return cuaSucceeded(options.state);
  };
  const screenshotResult = (target: ActionTarget): CuaResult<CuaScreenshot> => {
    const state = stateResult(target);
    if (state.status !== "succeeded") return state;
    return cuaSucceeded({
      surface: state.value.surface,
      capturedAt: state.value.capturedAt,
      mimeType: "image/png",
      width: 1,
      height: 1,
      pngBase64: "fake",
    });
  };

  return {
    async checkPermissions() {
      return cuaSucceeded(permissions);
    },
    async listApps() {
      if (permissions.driver !== "running") return cuaBlocked("CUA driver is unavailable");
      return cuaSucceeded(options.apps ?? []);
    },
    async listWindows() {
      record({ kind: "list_windows" });
      if (permissions.driver !== "running") return cuaBlocked("CUA driver is unavailable");
      return cuaSucceeded(options.windows ?? [options.state.surface]);
    },
    async launchApp({ appName, bundleId }) {
      record({ kind: "launch_app", appName, bundleId });
      return result();
    },
    async getWindowState(target) {
      record({ kind: "get_window_state", target });
      return stateResult(target);
    },
    async click(target) {
      record({ kind: "click", target });
      return result();
    },
    async typeText(target, text) {
      record({ kind: "type_text", target, text });
      return result();
    },
    async setValue(target, value) {
      record({ kind: "set_value", target, value });
      return result();
    },
    async screenshot(target) {
      record({ kind: "screenshot", target });
      return screenshotResult(target);
    },
    calls() {
      return [...calls];
    },
  };
}
