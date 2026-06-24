import type {
  ActionTarget,
  CuaActionResult,
  CuaApp,
  CuaPermissionReport,
  CuaWindow,
  CuaWindowState,
} from "@handsoff/contracts";

import type { CuaDriver } from "./driver";

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

  return {
    async checkPermissions() {
      return permissions;
    },
    async listApps() {
      return options.apps ?? [];
    },
    async listWindows() {
      record({ kind: "list_windows" });
      return options.windows ?? [options.state.surface];
    },
    async launchApp({ appName, bundleId }) {
      record({ kind: "launch_app", appName, bundleId });
      return result();
    },
    async getWindowState(target) {
      record({ kind: "get_window_state", target });
      return { status: "succeeded", summary: "Window state captured", state: options.state };
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
      return result();
    },
    calls() {
      return [...calls];
    },
  };
}
