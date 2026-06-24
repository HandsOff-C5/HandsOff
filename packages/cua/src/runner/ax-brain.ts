import { safeParseCuaAgentAction } from "@handsoff/contracts";

import type { BrainStep, BrainToolUse } from "./computer-use-loop";

// The model the AX CUA brain runs against. Opus 4.8 — same single source of
// truth the loop test of record can assert. Unlike the old pixel path this needs
// NO beta header: the AX action surface is a plain custom tool, not the
// computer_20251124 server tool.
export const CUA_AGENT_MODEL = "claude-opus-4-8";

// The custom tool the brain calls to act. One tool, one action object per call,
// discriminated on `kind` — the env maps each kind onto a `cua_*` driver command.
export const CUA_AGENT_TOOL_NAME = "cua_action";

// Build the AX-native action tool for `messages.create`. The input schema is
// permissive (kind + the union of per-kind fields) so the model fills the right
// fields; parseCuaAgentStep then validates strictly against the contract. The
// description teaches the grounding discipline: act by elementIndex from the
// latest snapshot; reach for click_point only on AX-blind surfaces.
export function buildCuaAgentTool(): Record<string, unknown> {
  return {
    name: CUA_AGENT_TOOL_NAME,
    description:
      "Operate the active window. Prefer `click`/`type_text`/`set_value` by `elementIndex` " +
      "from the most recent snapshot's elements (AX-native, works on backgrounded windows). " +
      "Use `snapshot` to re-read the window before acting; `click_point` (window-local pixels) " +
      "only for canvas/WebGL/video surfaces with no element. Stop calling the tool when the task " +
      "is complete.",
    input_schema: {
      type: "object",
      properties: {
        kind: {
          type: "string",
          enum: [
            "snapshot",
            "click",
            "click_point",
            "type_text",
            "set_value",
            "press_key",
            "hotkey",
            "scroll",
            "launch_app",
          ],
          description: "Which action to perform.",
        },
        elementIndex: {
          type: "integer",
          description:
            "Target element's index from the latest snapshot (click/type_text/set_value).",
        },
        x: { type: "number", description: "Window-local pixel X (click_point only)." },
        y: { type: "number", description: "Window-local pixel Y (click_point only)." },
        button: { type: "string", enum: ["left", "right", "middle"] },
        text: { type: "string", description: "Text to type (type_text)." },
        value: { type: "string", description: "Value to set (set_value)." },
        key: { type: "string", description: "Key name for press_key, e.g. return, tab, a." },
        modifiers: { type: "array", items: { type: "string" } },
        keys: {
          type: "array",
          items: { type: "string" },
          description: 'Chord for hotkey, e.g. ["cmd","c"] (≥2 keys).',
        },
        direction: { type: "string", enum: ["up", "down", "left", "right"] },
        by: { type: "string", enum: ["line", "page"] },
        amount: { type: "integer" },
        appName: { type: "string", description: "App to launch (launch_app)." },
        bundleId: { type: "string" },
      },
      required: ["kind"],
    },
  };
}

// The minimal shape of an Anthropic message we parse — kept structural so the
// pure parser doesn't depend on the SDK types. The real adapter passes the SDK's
// Message straight in.
type ContentBlockLike = {
  type?: string;
  text?: string;
  id?: string;
  name?: string;
  input?: unknown;
};
type MessageLike = { stop_reason?: string | null; content?: readonly ContentBlockLike[] };

// Turn a model turn into the loop's BrainStep: concatenate narration text,
// validate each `cua_action` tool_use input into a CuaAgentAction, and derive the
// stop reason (a present action always means "run it"; an explicit refusal with
// no actions is surfaced; otherwise no actions => end_turn => task complete).
export function parseCuaAgentStep(message: unknown): BrainStep {
  const { stop_reason, content = [] } = (message ?? {}) as MessageLike;

  const texts: string[] = [];
  const actions: BrainToolUse[] = [];

  for (const block of content) {
    if (block.type === "text" && typeof block.text === "string") {
      texts.push(block.text);
      continue;
    }
    if (block.type === "tool_use") {
      if (block.name !== CUA_AGENT_TOOL_NAME) {
        throw new Error(`Unsupported tool in CUA agent loop: ${block.name ?? "<unnamed>"}`);
      }
      const parsed = safeParseCuaAgentAction(block.input);
      if (!parsed.success) {
        throw new Error(`Invalid CUA agent action from model: ${parsed.error.message}`);
      }
      actions.push({ id: block.id ?? "", action: parsed.data });
    }
  }

  const stopReason: BrainStep["stopReason"] =
    actions.length > 0 ? "tool_use" : stop_reason === "refusal" ? "refusal" : "end_turn";

  return { text: texts.join("\n"), actions, stopReason };
}
