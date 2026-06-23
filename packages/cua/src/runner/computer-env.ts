import type { ComputerAction } from "@handsoff/contracts";

import type { CuaInvoke } from "../tauri-driver";

import type { ActionOutcome, ComputerEnv } from "./computer-use-loop";

// A resolved driver call: either a pure delay (the `wait` action needs no
// driver) or a Tauri `cua_*` command with its args. `expectsScreenshot` marks
// the calls whose return value is a base64 screenshot to feed the next turn.
export type DriverCall =
  | { kind: "wait"; ms: number }
  | { kind: "invoke"; command: string; args: Record<string, unknown>; expectsScreenshot: boolean };

const SECONDS_TO_MS = 1000;

function invokeCall(
  command: string,
  args: Record<string, unknown>,
  expectsScreenshot = false,
): DriverCall {
  return { kind: "invoke", command, args, expectsScreenshot };
}

// Click family → one cua_pointer_click with a button + click count, plus an
// optional held modifier key (the API overloads `text` for this on clicks).
function clickCall(
  button: "left" | "right" | "middle",
  clicks: number,
  coordinate: readonly [number, number],
  modifier?: string,
): DriverCall {
  const args: Record<string, unknown> = { button, clicks, x: coordinate[0], y: coordinate[1] };
  if (modifier) args.modifier = modifier;
  return invokeCall("cua_pointer_click", args);
}

// Translate a computer_20251124 action into the cua-driver command that runs it.
// This is the contract between the brain's pixel actions and the (Mac-side)
// trycua/cua-driver sidecar; the Rust commands it names are built in CUA-0.
export function computerActionToDriverCall(action: ComputerAction): DriverCall {
  switch (action.action) {
    case "screenshot":
      return invokeCall("cua_screenshot", {}, true);
    case "zoom":
      return invokeCall("cua_screenshot", { region: action.region }, true);
    case "cursor_position":
      return invokeCall("cua_cursor_position", {});
    case "mouse_move":
      return invokeCall("cua_pointer_move", { x: action.coordinate[0], y: action.coordinate[1] });
    case "left_click":
      return clickCall("left", 1, action.coordinate, action.text);
    case "right_click":
      return clickCall("right", 1, action.coordinate, action.text);
    case "middle_click":
      return clickCall("middle", 1, action.coordinate, action.text);
    case "double_click":
      return clickCall("left", 2, action.coordinate, action.text);
    case "triple_click":
      return clickCall("left", 3, action.coordinate, action.text);
    case "left_click_drag":
      return invokeCall("cua_pointer_drag", {
        fromX: action.start_coordinate[0],
        fromY: action.start_coordinate[1],
        toX: action.coordinate[0],
        toY: action.coordinate[1],
      });
    case "left_mouse_down":
    case "left_mouse_up": {
      const args: Record<string, unknown> = {
        state: action.action === "left_mouse_down" ? "down" : "up",
      };
      if (action.coordinate) {
        args.x = action.coordinate[0];
        args.y = action.coordinate[1];
      }
      return invokeCall("cua_pointer_button", args);
    }
    case "scroll":
      return invokeCall("cua_scroll", {
        x: action.coordinate[0],
        y: action.coordinate[1],
        direction: action.scroll_direction,
        amount: action.scroll_amount,
        ...(action.text ? { modifier: action.text } : {}),
      });
    case "type":
      return invokeCall("cua_type", { text: action.text });
    case "key":
      return invokeCall("cua_key", { keys: action.text });
    case "hold_key":
      return invokeCall("cua_hold_key", {
        keys: action.text,
        durationMs: action.duration * SECONDS_TO_MS,
      });
    case "wait":
      return { kind: "wait", ms: action.duration * SECONDS_TO_MS };
  }
}

const realWait = (ms: number): Promise<void> => new Promise((resolve) => setTimeout(resolve, ms));

// The cua-driver-backed environment for the computer-use loop. The `invoke` is
// Tauri's command bridge (injected so the mapping is testable without Tauri);
// `wait` is injectable so tests don't sleep. A thrown driver call becomes an
// error outcome the loop feeds back to the brain rather than crashing.
export function createTauriComputerEnv(deps: {
  invoke: CuaInvoke;
  wait?: (ms: number) => Promise<void>;
}): ComputerEnv {
  const wait = deps.wait ?? realWait;
  return {
    async execute(action: ComputerAction): Promise<ActionOutcome> {
      const call = computerActionToDriverCall(action);
      if (call.kind === "wait") {
        await wait(call.ms);
        return { status: "ok" };
      }
      try {
        const result = await deps.invoke<unknown>(call.command, call.args);
        if (call.expectsScreenshot && typeof result === "string") {
          return { status: "ok", screenshot: result };
        }
        return { status: "ok" };
      } catch (caught) {
        return {
          status: "error",
          error: caught instanceof Error ? caught.message : String(caught),
        };
      }
    },
  };
}
