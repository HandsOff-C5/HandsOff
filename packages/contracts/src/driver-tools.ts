import { z } from "zod";

// ---------------------------------------------------------------------------
// The cua-driver tool surface (36 tools), as the driver self-describes it via
// `cua-driver list-tools`. This is the static enumeration of every tool the
// agentic loop (U3) can call through the generic `cua_driver_call` passthrough
// (U1). It MUST stay in sync with the driver's tool list — `driverToolSchema`
// is the validator the loop uses to reject a model-hallucinated tool name
// before it reaches the driver. (The plan's prose says "38"; the live driver
// reports 36 — the driver is the source of truth and this list mirrors it.)
//
// Lives in its own `contracts/driver-tools` module (not `action-plan` or
// `tool-risk`) deliberately: `tool-risk` needs the enum to key per-tool risk
// AND `action-plan` needs it to type the `tool_call` step's `tool`. Keeping the
// vocabulary dependency-free here lets BOTH import it without the
// `tool-risk -> action-plan -> tool-risk` import cycle that forced `tool_call`'s
// `tool` to a bare `z.string()` before.
export const DRIVER_TOOLS = [
  // session / cursor overlay
  "start_session",
  "end_session",
  "set_agent_cursor_enabled",
  "set_agent_cursor_motion",
  "set_agent_cursor_style",
  "get_agent_cursor_state",
  // perception (read-only)
  "get_window_state",
  "get_accessibility_tree",
  "get_cursor_position",
  "get_screen_size",
  "list_apps",
  "list_windows",
  "get_recording_state",
  "get_config",
  "check_permissions",
  "check_for_update",
  "zoom",
  // pointer navigation (read-only — no commit)
  "scroll",
  "move_cursor",
  // draft / reversible
  "type_text",
  "set_value",
  "launch_app",
  "bring_to_front",
  // mutating (context-dependent for click/key)
  "click",
  "right_click",
  "double_click",
  "drag",
  "press_key",
  "hotkey",
  "page",
  "set_config",
  "start_recording",
  "stop_recording",
  // destructive / external
  "kill_app",
  "replay_trajectory",
  "install_ffmpeg",
] as const;

export const driverToolSchema = z.enum(DRIVER_TOOLS);
export type DriverTool = z.infer<typeof driverToolSchema>;

export function safeParseDriverTool(input: unknown): z.SafeParseReturnType<unknown, DriverTool> {
  return driverToolSchema.safeParse(input);
}
