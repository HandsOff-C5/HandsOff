import {
  safeParseCuaWindowState,
  type CuaAgentAction,
  type CuaWindowState,
} from "@handsoff/contracts";

import type { CuaInvoke } from "../tauri-driver";

import type { ActionOutcome, ComputerEnv } from "./computer-use-loop";

// The active window the agent operates within. pid + window_id are loop context
// (resolved from the pointed-at referent), not model-chosen — so the brain can
// only act inside the window the user pointed at.
export type CuaAgentTarget = { pid: number; windowId: number };

// A resolved driver call: the `cua_*` command + its camelCase args (Tauri maps
// them to the snake_case Rust params). `expectsState` marks the call whose return
// is a CuaWindowState (snapshot) so the env reads the screenshot/elements from it.
export type AgentDriverCall = {
  command: string;
  args: Record<string, unknown>;
  expectsState: boolean;
};

// Translate one AX agent action into the cua-driver command that runs it. Pure +
// total over the action union, so the mapping is unit-tested without Tauri. The
// window target is folded into every windowed command; launch_app is global.
export function cuaAgentActionToDriverCall(
  action: CuaAgentAction,
  target: CuaAgentTarget,
): AgentDriverCall {
  const win = { pid: target.pid, windowId: target.windowId };
  switch (action.kind) {
    case "snapshot":
      return { command: "cua_get_window_state", args: { ...win }, expectsState: true };
    case "click":
      return {
        command: "cua_click",
        args: { ...win, elementIndex: action.elementIndex },
        expectsState: false,
      };
    case "click_point":
      return {
        command: "cua_click_point",
        args: {
          ...win,
          x: action.x,
          y: action.y,
          ...(action.button ? { button: action.button } : {}),
        },
        expectsState: false,
      };
    case "type_text":
      return {
        command: "cua_type_text",
        args: { ...win, elementIndex: action.elementIndex, text: action.text },
        expectsState: false,
      };
    case "set_value":
      return {
        command: "cua_set_value",
        args: { ...win, elementIndex: action.elementIndex, value: action.value },
        expectsState: false,
      };
    case "press_key":
      return {
        command: "cua_press_key",
        args: {
          ...win,
          key: action.key,
          ...(action.modifiers ? { modifiers: action.modifiers } : {}),
          ...(action.elementIndex !== undefined ? { elementIndex: action.elementIndex } : {}),
        },
        expectsState: false,
      };
    case "hotkey":
      return { command: "cua_hotkey", args: { ...win, keys: action.keys }, expectsState: false };
    case "scroll":
      return {
        command: "cua_scroll",
        args: {
          ...win,
          direction: action.direction,
          ...(action.by ? { by: action.by } : {}),
          ...(action.amount !== undefined ? { amount: action.amount } : {}),
          ...(action.elementIndex !== undefined ? { elementIndex: action.elementIndex } : {}),
        },
        expectsState: false,
      };
    case "launch_app":
      return {
        command: "cua_launch_app",
        args: {
          appName: action.appName,
          ...(action.bundleId ? { bundleId: action.bundleId } : {}),
        },
        expectsState: false,
      };
  }
}

// Render the window's elements as text the model can ground on even without the
// image: one `[index] role "label"` line per element. The element_index is the
// click handle, so leading with it teaches the model how to address targets.
export function summarizeWindowState(state: CuaWindowState): string {
  const header = `Window "${state.surface.title}" (${state.surface.app}) — ${state.elementCount} elements:`;
  const lines = state.elements.map((element) => {
    const index = element.index ?? "?";
    const role = element.role ?? "?";
    const label = element.label ?? "";
    const value = element.value ? ` = "${element.value}"` : "";
    return `[${index}] ${role} "${label}"${value}`;
  });
  return [header, ...lines].join("\n");
}

function stateOutcome(raw: unknown): ActionOutcome {
  const parsed = safeParseCuaWindowState(raw);
  if (!parsed.success) {
    return { status: "error", error: `Invalid window state: ${parsed.error.message}` };
  }
  const text = summarizeWindowState(parsed.data);
  const png = parsed.data.screenshot?.pngBase64;
  return png !== undefined ? { status: "ok", screenshot: png, text } : { status: "ok", text };
}

// The cua-driver-backed environment for the AX agent loop. `invoke` is Tauri's
// command bridge (injected so the mapping is testable without Tauri). After every
// non-snapshot action it re-reads the window so the brain always sees the result
// of what it just did (set `refreshAfterAction: false` to skip). A thrown driver
// call becomes an error outcome the loop feeds back rather than crashing.
export function createTauriCuaAgentEnv(deps: {
  invoke: CuaInvoke;
  target: CuaAgentTarget;
  refreshAfterAction?: boolean;
}): ComputerEnv {
  const refreshAfterAction = deps.refreshAfterAction ?? true;
  const snapshot = (): AgentDriverCall =>
    cuaAgentActionToDriverCall({ kind: "snapshot" }, deps.target);

  return {
    async execute(action: CuaAgentAction): Promise<ActionOutcome> {
      const call = cuaAgentActionToDriverCall(action, deps.target);
      try {
        const result = await deps.invoke<unknown>(call.command, call.args);
        if (call.expectsState) {
          return stateOutcome(result);
        }
        // launch_app retargeting is a follow-up; other actions refresh the
        // active window so the model sees the post-action state.
        if (refreshAfterAction && action.kind !== "launch_app") {
          const refreshed = await deps.invoke<unknown>(snapshot().command, snapshot().args);
          return stateOutcome(refreshed);
        }
        return { status: "ok", text: `Performed ${action.kind}` };
      } catch (caught) {
        return {
          status: "error",
          error: caught instanceof Error ? caught.message : String(caught),
        };
      }
    },
  };
}
