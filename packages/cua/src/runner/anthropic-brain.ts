import { safeParseComputerAction } from "@handsoff/contracts";

import type { BrainStep, BrainToolUse } from "./computer-use-loop";

// The model and beta header the CUA brain runs against. Pinned here (rather than
// inlined at the call site) so the demo target is a single source of truth and
// the loop test of record can assert them. Opus 4.8 with the current
// computer-use beta — see docs/RESEARCH-CUA.md and the computer-use tool docs.
export const COMPUTER_USE_MODEL = "claude-opus-4-8";
export const COMPUTER_USE_BETA = "computer-use-2025-11-24";

// The Claude computer-use tool name is fixed by the API.
const COMPUTER_TOOL_NAME = "computer";

// Build the `computer_20251124` tool definition for `messages.create`. The
// display geometry must match the screenshots the env returns; the host scales
// oversized screenshots and maps coordinates back (see the computer-use docs).
export function buildComputerUseTool(opts: {
  widthPx: number;
  heightPx: number;
  displayNumber?: number;
  enableZoom?: boolean;
}): Record<string, unknown> {
  const tool: Record<string, unknown> = {
    type: "computer_20251124",
    name: COMPUTER_TOOL_NAME,
    display_width_px: opts.widthPx,
    display_height_px: opts.heightPx,
  };
  if (opts.displayNumber !== undefined) tool.display_number = opts.displayNumber;
  if (opts.enableZoom) tool.enable_zoom = true;
  return tool;
}

// The minimal shape of an Anthropic (beta) message we parse — kept structural so
// the pure parser doesn't depend on the SDK types. The real adapter passes the
// SDK's BetaMessage straight in.
type ContentBlockLike = {
  type?: string;
  text?: string;
  id?: string;
  name?: string;
  input?: unknown;
};
type MessageLike = { stop_reason?: string | null; content?: readonly ContentBlockLike[] };

// Turn a model turn into the loop's BrainStep: concatenate narration text,
// validate each `computer` tool_use input into a ComputerAction, and derive the
// stop reason (a present action always means "run it", regardless of the API's
// reported stop_reason; an explicit refusal with no actions is surfaced).
export function parseBrainStep(message: unknown): BrainStep {
  const { stop_reason, content = [] } = (message ?? {}) as MessageLike;

  const texts: string[] = [];
  const actions: BrainToolUse[] = [];

  for (const block of content) {
    if (block.type === "text" && typeof block.text === "string") {
      texts.push(block.text);
      continue;
    }
    if (block.type === "tool_use") {
      if (block.name !== COMPUTER_TOOL_NAME) {
        throw new Error(`Unsupported tool in computer-use loop: ${block.name ?? "<unnamed>"}`);
      }
      const parsed = safeParseComputerAction(block.input);
      if (!parsed.success) {
        throw new Error(`Invalid computer action from model: ${parsed.error.message}`);
      }
      actions.push({ id: block.id ?? "", action: parsed.data });
    }
  }

  const stopReason: BrainStep["stopReason"] =
    actions.length > 0 ? "tool_use" : stop_reason === "refusal" ? "refusal" : "end_turn";

  return { text: texts.join("\n"), actions, stopReason };
}
