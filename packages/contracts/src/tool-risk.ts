import { z } from "zod";

import { riskLevelRequiresApproval } from "./action-plan";
import type { RiskLevel } from "./action-plan";
import { driverToolSchema } from "./driver-tools";
import type { DriverTool } from "./driver-tools";

// The cua-driver tool surface (DRIVER_TOOLS / driverToolSchema / DriverTool /
// safeParseDriverTool) now lives in the dependency-free `./driver-tools` module
// so `action-plan` can type `tool_call.tool` against the enum without the
// `tool-risk -> action-plan` import cycle. This module keys per-tool RISK off
// that vocabulary (importers reach the vocabulary via the `@handsoff/contracts`
// barrel or `./driver-tools` directly).
//
// Lives in `contracts` (not `intent`) deliberately: both `intent` (the loop's
// reasoning side) and `actions` (the gate's execution side) need to key risk
// off the tool name, and the boundary rule forbids one area package importing
// another — so the shared tool vocabulary + risk classification can only live
// in `contracts`, the one package every area may import.

// ---------------------------------------------------------------------------
// Static per-tool risk classification (plan KD3). Each tool is keyed to one of
// the four existing tiers in `RISK_LEVELS`. The gate itself
// (`riskLevelRequiresApproval`) is unchanged: read_only/reversible auto-run,
// mutating/destructive_external require approval.
//
// Two tools carry context-dependent risk that the flat map only gives a *base*
// for; `riskForToolCall` escalates them from a target/argument inspection:
//   - `click`/`right_click`/`double_click`: base reversible (navigation —
//     opening a dropdown/menu/tab must NOT prompt), escalated to mutating when
//     the target element commits (Send/Delete/…). See COMMIT_PATTERNS.
//   - `press_key`/`hotkey`: base mutating (a send-chord like ⌘↵ commits),
//     de-escalated to read_only only for obviously-benign navigation keys.
//   - `page`: base mutating, escalated to destructive_external for
//     `enable_javascript_apple_events`; de-escalated to read_only for the
//     read actions (`get_text`/`query_dom`).
//
// DELIBERATE TRADEOFF (owner's model): `type_text` and `set_value` are
// classified `reversible`, NOT `mutating` as today. The product default is
// "draft, don't send" — composing text into a field is reversible (clear it),
// and a draft that happens to auto-submit is the accepted risk, backstopped by
// the audit trail + always-available interrupt (KD6). Erring to draft = free is
// intentional so dictation flows without a prompt on every keystroke.
const TOOL_RISK: Record<DriverTool, RiskLevel> = {
  // read_only — perception, pointer navigation, cursor overlay, config reads
  start_session: "read_only",
  end_session: "read_only",
  set_agent_cursor_enabled: "read_only",
  set_agent_cursor_motion: "read_only",
  set_agent_cursor_style: "read_only",
  get_agent_cursor_state: "read_only",
  get_window_state: "read_only",
  get_accessibility_tree: "read_only",
  get_cursor_position: "read_only",
  get_screen_size: "read_only",
  list_apps: "read_only",
  list_windows: "read_only",
  get_recording_state: "read_only",
  get_config: "read_only",
  check_permissions: "read_only",
  check_for_update: "read_only",
  zoom: "read_only",
  scroll: "read_only",
  move_cursor: "read_only",

  // reversible / draft — composing, launching, foregrounding
  type_text: "reversible",
  set_value: "reversible",
  launch_app: "reversible",
  bring_to_front: "reversible",

  // mutating — bases; click/key/page get refined by riskForToolCall
  click: "reversible", // base: navigation; escalated to mutating on a commit element
  right_click: "reversible", // base: opens a context menu (navigation)
  double_click: "reversible", // base: open/activate; escalated on a commit element
  drag: "mutating",
  press_key: "mutating", // base: send-chords commit; de-escalated for nav keys
  hotkey: "mutating", // base: ⌘↵ etc. commit; de-escalated for nav keys
  page: "mutating", // base: execute_javascript / click_element; refined by action
  set_config: "mutating",
  start_recording: "mutating",
  stop_recording: "mutating",

  // destructive_external — process kill, AppleEvents patch, replay, installs
  kill_app: "destructive_external",
  replay_trajectory: "destructive_external",
  install_ffmpeg: "destructive_external",
};

// A click whose target element commits (sends/deletes/buys) must gate even
// though a bare click is free navigation. Word-ish, case-insensitive match
// against the element's AX role/title/label. Kept intentionally conservative —
// "unknown-but-suspect verbs default to gated" is enforced by leaving an
// unidentifiable click target gated (see riskForToolCall).
export const COMMIT_PATTERNS: readonly string[] = [
  "send",
  "post",
  "submit",
  "reply",
  "delete",
  "remove",
  "buy",
  "purchase",
  "order",
  "confirm",
  "pay",
  "publish",
  "discard",
  "trash",
];

// Navigation keys that move focus/scroll without committing. Anything NOT in
// this set (return/enter, ⌘-chords, etc.) keeps press_key/hotkey gated.
const NAVIGATION_KEYS: ReadonlySet<string> = new Set([
  "up",
  "down",
  "left",
  "right",
  "pageup",
  "pagedown",
  "home",
  "end",
  "escape",
  "esc",
  "tab",
]);

// `shift` is a non-committing modifier: shift+tab is reverse-tab navigation,
// shift+arrow extends a selection — neither commits. The action modifiers
// (cmd/ctrl/option/fn) DO change a nav key into a command (⌘← = back, ⌥↑ = move
// line), so a chord carrying any of those is gated.
const NAVIGATION_MODIFIERS: ReadonlySet<string> = new Set(["shift"]);

// `page` sub-actions split by risk: reads are free, JS/DOM mutation gates,
// the AppleEvents patch is destructive_external.
const PAGE_READ_ACTIONS: ReadonlySet<string> = new Set(["get_text", "query_dom"]);
const PAGE_DESTRUCTIVE_ACTIONS: ReadonlySet<string> = new Set(["enable_javascript_apple_events"]);

const CLICK_TOOLS: ReadonlySet<DriverTool> = new Set(["click", "right_click", "double_click"]);
const KEY_TOOLS: ReadonlySet<DriverTool> = new Set(["press_key", "hotkey"]);

// Optional metadata describing what a single tool call targets, used only to
// refine the context-dependent tools. Everything is optional: when a click
// arrives with no element info we cannot prove it is navigation, so we gate
// (safe default).
export type ToolCallTarget = {
  // The AX element a click/double_click/right_click addresses.
  element?: {
    role?: string;
    title?: string;
    label?: string;
    value?: string;
  };
  // For press_key: the key name (e.g. "return", "down").
  key?: string;
  // For hotkey: the chord, e.g. ["cmd", "return"].
  keys?: readonly string[];
  // For page: the sub-action ("execute_javascript" | "get_text" | ...).
  pageAction?: string;
};

function matchesCommitPattern(text: string | undefined): boolean {
  if (!text) return false;
  const haystack = text.toLowerCase();
  // Word-ish match: the commit verb appears delimited by non-letters (or string
  // edges), so "Resend" / "Description" don't trip "send"/"post" but
  // "Send", "Send Now", "Re-send", "Post reply" do.
  return COMMIT_PATTERNS.some((verb) => {
    const pattern = new RegExp(`(^|[^a-z])${verb}([^a-z]|$)`, "i");
    return pattern.test(haystack);
  });
}

function clickTargetCommits(target?: ToolCallTarget): boolean {
  const element = target?.element;
  // No element metadata at all → we cannot prove this is navigation → gate.
  if (!element) return true;
  return (
    matchesCommitPattern(element.title) ||
    matchesCommitPattern(element.label) ||
    matchesCommitPattern(element.value) ||
    matchesCommitPattern(element.role)
  );
}

function isNavigationKey(key: string): boolean {
  const k = key.toLowerCase();
  return NAVIGATION_KEYS.has(k) || NAVIGATION_MODIFIERS.has(k);
}

function keyChordCommits(target?: ToolCallTarget): boolean {
  // hotkey: a bare navigation chord (e.g. ["shift","tab"]) does not commit; any
  // action modifier (cmd/ctrl/option/fn) or a committing key (return/letter/…)
  // does.
  if (target?.keys && target.keys.length > 0) {
    return !target.keys.every(isNavigationKey);
  }
  // press_key: single key. Only the explicit navigation set is free; an
  // unknown/missing key stays gated (safe default).
  if (target?.key) {
    return !NAVIGATION_KEYS.has(target.key.toLowerCase());
  }
  return true;
}

function pageRisk(target?: ToolCallTarget): RiskLevel {
  const action = target?.pageAction;
  if (action && PAGE_DESTRUCTIVE_ACTIONS.has(action)) return "destructive_external";
  if (action && PAGE_READ_ACTIONS.has(action)) return "read_only";
  // execute_javascript / click_element / unknown → mutating (gated).
  return "mutating";
}

// The pure per-call gate input. `riskForToolCall` is the single place the loop
// (U3) and the executor (`run-approved-plan`) ask "does THIS call need
// approval?". It NEVER trusts a model-supplied risk/`requires_approval` — risk
// is derived from the tool (+ target) here, mirroring `run-approved-plan.ts`'s
// "derive the gate from risk, never trust the claim" rule.
export function riskForToolCall(tool: DriverTool, target?: ToolCallTarget): RiskLevel {
  if (CLICK_TOOLS.has(tool)) {
    return clickTargetCommits(target) ? "mutating" : "reversible";
  }
  if (KEY_TOOLS.has(tool)) {
    return keyChordCommits(target) ? "mutating" : "read_only";
  }
  if (tool === "page") {
    return pageRisk(target);
  }
  return TOOL_RISK[tool];
}

// An UNKNOWN tool name (not in DRIVER_TOOLS) defaults to `mutating` — gated.
// Safe default: a tool we cannot classify must never auto-run. Used by the loop
// when it receives a tool name string straight from the model.
export function riskForToolName(tool: string, target?: ToolCallTarget): RiskLevel {
  const parsed = driverToolSchema.safeParse(tool);
  if (!parsed.success) return "mutating";
  return riskForToolCall(parsed.data, target);
}

export type ToolCall = {
  tool: DriverTool;
  target?: ToolCallTarget;
};

// Effective risk of a set of intended calls is the MAX over their per-call
// risks, so the existing plan-level approval logic (`requiredApprovalResult`)
// keeps working unchanged: a goal that wants to read + send is a "send" for
// gating purposes.
export function effectiveToolCallRisk(calls: readonly ToolCall[]): RiskLevel {
  let max: RiskLevel = "read_only";
  for (const call of calls) {
    const risk = riskForToolCall(call.tool, call.target);
    if (riskRank(risk) > riskRank(max)) max = risk;
  }
  return max;
}

const RISK_RANK: Record<RiskLevel, number> = {
  read_only: 0,
  reversible: 1,
  mutating: 2,
  destructive_external: 3,
};

function riskRank(risk: RiskLevel): number {
  return RISK_RANK[risk];
}

// Convenience: does this single call need human approval before it runs?
export function toolCallRequiresApproval(tool: DriverTool, target?: ToolCallTarget): boolean {
  return riskLevelRequiresApproval(riskForToolCall(tool, target));
}

// The risk-relevant subset of what a tool call targets. Validated structurally
// elsewhere (the driver owns the real per-tool schema); here we only model the
// optional fields the gate + the per-call audit record need. `keys` is readonly
// so the inferred type matches the canonical `ToolCallTarget` above (immutable
// per the repo's immutability rule).
export const toolCallTargetSchema = z.object({
  element: z
    .object({
      role: z.string().optional(),
      title: z.string().optional(),
      label: z.string().optional(),
      value: z.string().optional(),
    })
    .optional(),
  key: z.string().optional(),
  keys: z.array(z.string()).readonly().optional(),
  pageAction: z.string().optional(),
});

export const toolCallSchema = z.object({
  tool: driverToolSchema,
  target: toolCallTargetSchema.optional(),
});
