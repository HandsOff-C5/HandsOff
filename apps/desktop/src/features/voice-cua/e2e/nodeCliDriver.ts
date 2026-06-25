import { execFileSync } from "node:child_process";

import {
  cuaAppSchema,
  cuaPermissionReportSchema,
  cuaScreenshotSchema,
  cuaWindowSchema,
  safeParseCuaWindowState,
  safeParseDriverToolDefinitions,
  type ActionTarget,
  type CuaApp,
  type CuaActionResult,
  type CuaPermissionReport,
  type CuaResult,
  type CuaScreenshot,
  type CuaWindow,
  type CuaWindowState,
  type DriverToolDefinition,
} from "@handsoff/contracts";
import {
  cuaBlocked,
  cuaFailed,
  cuaSucceeded,
  normalizeCuaActionResult,
  type CuaDriver,
} from "@handsoff/cua";

// A real CuaDriver backed by the `cua-driver` CLI for the live e2e harness.
//
// It is the Node-side mirror of `apps/desktop/src-tauri/src/commands/cua.rs`:
// every method shells out to `cua-driver` exactly as the Rust commands do and
// maps the raw driver JSON onto the same `@handsoff/contracts` shapes the
// tauri-driver produces. Replicating the Rust mapping (not importing it) is the
// point — it lets the loop run against the REAL driver surface from a test
// process, catching the worker/driver/binding integration bugs the fake-driver
// unit tests cannot.
//
// SIDE-EFFECT SAFETY: this drives the user's real desktop. The harness keeps to
// read-only perception (`list_windows`, `get_window_state`, `list-tools`) and
// the loop's chosen tool calls; any mutating tool is only ever dispatched
// against a disposable scratch window the test launches itself.

const CUA_DRIVER_BIN = process.env.HANDSOFF_CUA_DRIVER_BIN ?? "cua-driver";

// Raw `list_windows` window shape (the driver's snake_case wire format). Only
// the fields the contract mapping needs are modeled; the driver emits more.
interface DriverWindow {
  readonly app_name: string;
  readonly title: string;
  readonly pid: number;
  readonly window_id: number;
  readonly is_on_screen: boolean;
  readonly z_index: number;
}

export interface NodeCliCall {
  readonly tool: string;
  readonly args: Record<string, unknown>;
}

export interface NodeCliCuaDriver extends CuaDriver {
  // Every generic `driver.call(tool, args)` the loop dispatched, in order. The
  // e2e assertions read this to check the loop's chosen tool calls (and, for
  // Bug A, that a failing call is not repeated).
  calls(): readonly NodeCliCall[];
}

function errorMessage(caught: unknown): string {
  return caught instanceof Error ? caught.message : String(caught);
}

// Run `cua-driver <args>` and return stdout text. A non-zero exit (unknown
// tool, malformed arg) throws with the driver's stderr, mirroring
// `run_cua_raw`'s typed Err in cua.rs.
function runCuaText(args: readonly string[]): string {
  try {
    return execFileSync(CUA_DRIVER_BIN, args, {
      encoding: "utf8",
      maxBuffer: 64 * 1024 * 1024,
    });
  } catch (caught) {
    const stderr = (caught as { stderr?: Buffer | string }).stderr;
    const detail = stderr ? String(stderr).trim() : errorMessage(caught);
    throw new Error(`cua-driver failed: ${detail}`);
  }
}

function runCuaJson(args: readonly string[]): unknown {
  const stdout = runCuaText(args);
  try {
    return JSON.parse(stdout);
  } catch (caught) {
    throw new Error(`cua-driver returned invalid JSON: ${errorMessage(caught)}`);
  }
}

// Generic `call <tool> <json>`, returning parsed JSON when the tool prints it
// and the trimmed confirmation line (as a string) otherwise — exactly
// `run_cua_value` in cua.rs, so an action tool's prose line never fails.
function runCuaValue(tool: string, args: Record<string, unknown>): unknown {
  const stdout = runCuaText(["call", tool, JSON.stringify(args ?? {})]).trim();
  try {
    return JSON.parse(stdout);
  } catch {
    return stdout;
  }
}

// Map one raw driver window onto the CuaWindow contract — the same id/title/
// availability/access mapping as cua.rs `map_window`.
function mapWindow(window: DriverWindow, focused: boolean): CuaWindow {
  return {
    id: `${window.pid}:${window.window_id}`,
    title: window.title.length > 0 ? window.title : window.app_name,
    app: window.app_name,
    pid: window.pid,
    windowId: window.window_id,
    availability: window.is_on_screen ? "available" : "unknown",
    accessStatus: "accessible",
    focused,
  };
}

// `list_windows` → CuaWindow[], with the frontmost (max z_index) window flagged
// focused, mirroring cua_list_windows.
function listWindowsRaw(): CuaWindow[] {
  const raw = runCuaJson(["call", "list_windows", JSON.stringify({ on_screen_only: true })]);
  const windows = (raw as { windows?: DriverWindow[] }).windows ?? [];
  const frontmost = windows.reduce<number | undefined>(
    (max, window) => (max === undefined || window.z_index > max ? window.z_index : max),
    undefined,
  );
  return windows.map((window) => mapWindow(window, window.z_index === frontmost));
}

// Resolve an ActionTarget to a concrete pid/windowId, mirroring tauri-driver's
// `resolve`: prefer a pre-resolved surface, then the named app, then focused,
// then first usable window.
function resolveSurface(target: ActionTarget, windows: readonly CuaWindow[]): CuaWindow | null {
  const surface = target.surface;
  if (surface.pid !== undefined && surface.windowId !== undefined) {
    return { ...surface, focused: false } as CuaWindow;
  }
  const usable = windows.filter(
    (window) =>
      window.availability === "available" &&
      window.accessStatus === "accessible" &&
      !window.app.toLowerCase().includes("cua driver"),
  );
  const appName = surface.app.trim();
  const named =
    appName && appName !== "Current app"
      ? usable.find((window) => window.app.toLowerCase() === appName.toLowerCase())
      : undefined;
  return named ?? usable.find((window) => window.focused) ?? usable[0] ?? null;
}

export function createNodeCliCuaDriver(): NodeCliCuaDriver {
  const calls: NodeCliCall[] = [];

  function listWindows(): Promise<CuaResult<readonly CuaWindow[]>> {
    try {
      const windows = listWindowsRaw();
      const parsed = cuaWindowSchema.array().safeParse(windows);
      return Promise.resolve(
        parsed.success
          ? cuaSucceeded(parsed.data)
          : cuaFailed(`Invalid CUA windows: ${parsed.error.message}`),
      );
    } catch (caught) {
      return Promise.resolve(cuaFailed(errorMessage(caught)));
    }
  }

  function getWindowState(target: ActionTarget): Promise<CuaResult<CuaWindowState>> {
    try {
      const window = resolveSurface(target, listWindowsRaw());
      if (!window) return Promise.resolve(cuaBlocked("No accessible CUA window was found"));
      const raw = runCuaJson([
        "call",
        "get_window_state",
        JSON.stringify({ pid: window.pid, window_id: window.windowId, capture_mode: "ax" }),
      ]);
      const elementCount =
        typeof (raw as { element_count?: unknown }).element_count === "number"
          ? (raw as { element_count: number }).element_count
          : 0;
      const parsed = safeParseCuaWindowState({
        surface: window,
        elementCount,
        elements: [],
        capturedAt: new Date().toISOString(),
      });
      return Promise.resolve(
        parsed.success
          ? cuaSucceeded(parsed.data)
          : cuaFailed(`Invalid CUA window state: ${parsed.error.message}`),
      );
    } catch (caught) {
      return Promise.resolve(cuaFailed(errorMessage(caught)));
    }
  }

  return {
    calls: () => calls,

    checkPermissions(): Promise<CuaResult<CuaPermissionReport>> {
      try {
        const raw = runCuaJson(["permissions", "status", "--json"]) as {
          accessibility?: boolean;
          screen_recording?: boolean;
        };
        const report = cuaPermissionReportSchema.safeParse({
          accessibility: raw.accessibility ? "granted" : "denied",
          screenRecording: raw.screen_recording ? "granted" : "denied",
          driver: "running",
        });
        return Promise.resolve(
          report.success
            ? cuaSucceeded(report.data)
            : cuaFailed(`Invalid CUA permission report: ${report.error.message}`),
        );
      } catch (caught) {
        return Promise.resolve(cuaFailed(errorMessage(caught)));
      }
    },

    listApps(): Promise<CuaResult<readonly CuaApp[]>> {
      try {
        const raw = runCuaJson(["call", "list_apps", "{}"]) as {
          apps?: Array<{
            active: boolean;
            bundle_id?: string | null;
            name: string;
            pid: number;
            running: boolean;
          }>;
        };
        const apps = (raw.apps ?? []).map((app) => ({
          id: app.bundle_id ?? app.name.toLowerCase(),
          name: app.name,
          ...(app.pid > 0 ? { pid: app.pid } : {}),
          ...(app.bundle_id ? { bundleId: app.bundle_id } : {}),
          running: app.running,
          active: app.active,
        }));
        const parsed = cuaAppSchema.array().safeParse(apps);
        return Promise.resolve(
          parsed.success
            ? cuaSucceeded(parsed.data)
            : cuaFailed(`Invalid CUA apps: ${parsed.error.message}`),
        );
      } catch (caught) {
        return Promise.resolve(cuaFailed(errorMessage(caught)));
      }
    },

    listWindows,

    launchApp({ appName, bundleId }): Promise<CuaActionResult> {
      try {
        runCuaValue("launch_app", { name: appName, ...(bundleId ? { bundle_id: bundleId } : {}) });
        return Promise.resolve({ status: "succeeded", summary: "Launched requested app" });
      } catch (caught) {
        return Promise.resolve({ status: "failed", error: errorMessage(caught) });
      }
    },

    getWindowState,

    click(target): Promise<CuaActionResult> {
      try {
        const window = resolveSurface(target, listWindowsRaw());
        if (!window) {
          return Promise.resolve({
            status: "blocked",
            reason: "No accessible CUA window was found",
          });
        }
        const params: Record<string, unknown> = { pid: window.pid, window_id: window.windowId };
        if (target.elementIndex !== undefined) params.element_index = target.elementIndex;
        return Promise.resolve(normalizeCuaActionResult(runCuaValue("click", params)));
      } catch (caught) {
        return Promise.resolve({ status: "failed", error: errorMessage(caught) });
      }
    },

    typeText(target, text): Promise<CuaActionResult> {
      try {
        const window = resolveSurface(target, listWindowsRaw());
        if (!window) {
          return Promise.resolve({
            status: "blocked",
            reason: "No accessible CUA window was found",
          });
        }
        const params: Record<string, unknown> = {
          pid: window.pid,
          window_id: window.windowId,
          text,
        };
        if (target.elementIndex !== undefined) params.element_index = target.elementIndex;
        return Promise.resolve(normalizeCuaActionResult(runCuaValue("type_text", params)));
      } catch (caught) {
        return Promise.resolve({ status: "failed", error: errorMessage(caught) });
      }
    },

    setValue(target, value): Promise<CuaActionResult> {
      try {
        const window = resolveSurface(target, listWindowsRaw());
        if (!window) {
          return Promise.resolve({
            status: "blocked",
            reason: "No accessible CUA window was found",
          });
        }
        const params: Record<string, unknown> = {
          pid: window.pid,
          window_id: window.windowId,
          value,
        };
        if (target.elementIndex !== undefined) params.element_index = target.elementIndex;
        return Promise.resolve(normalizeCuaActionResult(runCuaValue("set_value", params)));
      } catch (caught) {
        return Promise.resolve({ status: "failed", error: errorMessage(caught) });
      }
    },

    screenshot(target): Promise<CuaResult<CuaScreenshot>> {
      try {
        const window = resolveSurface(target, listWindowsRaw());
        if (!window) return Promise.resolve(cuaBlocked("No accessible CUA window was found"));
        const raw = runCuaJson([
          "call",
          "get_window_state",
          JSON.stringify({ pid: window.pid, window_id: window.windowId, capture_mode: "vision" }),
        ]) as Record<string, unknown>;
        const parsed = cuaScreenshotSchema.safeParse({
          surface: window,
          mimeType: raw.screenshot_mime_type,
          width: raw.screenshot_width,
          height: raw.screenshot_height,
          pngBase64: raw.screenshot_png_b64,
          capturedAt: new Date().toISOString(),
        });
        return Promise.resolve(
          parsed.success
            ? cuaSucceeded(parsed.data)
            : cuaFailed(`Invalid CUA screenshot: ${parsed.error.message}`),
        );
      } catch (caught) {
        return Promise.resolve(cuaFailed(errorMessage(caught)));
      }
    },

    // Generic passthrough — the loop's full-surface dispatch path (U1). Every
    // call is recorded so the test can assert the loop's chosen tool sequence.
    call(tool, input): Promise<CuaResult<unknown>> {
      const args = (input ?? {}) as Record<string, unknown>;
      calls.push({ tool, args });
      try {
        return Promise.resolve(cuaSucceeded(runCuaValue(tool, args)));
      } catch (caught) {
        return Promise.resolve(cuaFailed(errorMessage(caught)));
      }
    },

    listTools(): Promise<CuaResult<readonly DriverToolDefinition[]>> {
      try {
        const listing = runCuaText(["list-tools"]);
        const definitions = listing
          .split("\n")
          .map((line) => line.split(/:\s(.+)/s))
          .filter(
            (parts): parts is [string, string, string] =>
              parts.length >= 2 && parts[0]!.trim().length > 0,
          )
          .map(([name, description]) => {
            const trimmedName = name.trim();
            let inputSchema: unknown = null;
            try {
              const describe = runCuaText(["describe", trimmedName]);
              const marker = describe.split("input_schema:")[1];
              if (marker) {
                const start = marker.indexOf("{");
                if (start >= 0) inputSchema = JSON.parse(marker.slice(start).trim());
              }
            } catch {
              inputSchema = null;
            }
            return { name: trimmedName, description: description.trim(), inputSchema };
          });
        const parsed = safeParseDriverToolDefinitions(definitions);
        return Promise.resolve(
          parsed.success
            ? cuaSucceeded(parsed.data)
            : cuaFailed(`Invalid CUA tool catalog: ${parsed.error.message}`),
        );
      } catch (caught) {
        return Promise.resolve(cuaFailed(errorMessage(caught)));
      }
    },
  };
}
