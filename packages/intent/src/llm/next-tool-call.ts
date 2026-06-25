import OpenAI from "openai";
import { zodResponseFormat } from "openai/helpers/zod";
import { z } from "zod";

import {
  riskForToolName,
  safeParseDriverTool,
  type DriverToolDefinition,
  type IntentInput,
  type ResolvedIntent,
} from "@handsoff/contracts";

import { blockedIntent } from "../fuse-intent";
import { requiresApproval } from "../risk";
import { buildNextToolCallMessages } from "./prompt";
import type { OpenAiIntentClient } from "./openai-resolver";

// The autonomous loop's "head" (U3b): instead of a whole 6-kind ActionPlan, the
// model returns the NEXT driver tool call toward the goal given the live
// perception snapshot — or signals the goal is done / needs clarification /
// is blocked. We keep the existing `client.chat.completions.parse` +
// `zodResponseFormat` structured-output path (the CF Worker speaks exactly that),
// rather than raw OpenAI function-calling which would need a different completion
// method + a Worker contract change across the network boundary.
export const nextToolCallSchema = z.object({
  // act = call a tool; done = goal already satisfied; clarify = ambiguous;
  // blocked = impossible/unsafe.
  status: z.enum(["act", "done", "clarify", "blocked"]),
  // The driver tool to call when status is "act". Validated against the real
  // driver surface (DRIVER_TOOLS) downstream — a hallucinated name is blocked.
  tool: z.string().nullable(),
  // The tool's raw flat args as a JSON object STRING (the driver's own
  // snake_case shape, e.g. {"pid":42,"window_id":7,"direction":"down"}). It is a
  // string — not an open object — because OpenAI strict structured outputs reject
  // open objects (z.record); parsed back into a record downstream by parseToolArgs.
  args: z.string().nullable(),
  // One-line reasoning for the chosen action (audited; shown in the preview).
  rationale: z.string(),
  // Filled when status is "done": what was accomplished.
  summary: z.string().nullable(),
  // Filled when status is "clarify"/"blocked": why the loop can't act.
  reason: z.string().nullable(),
});
export type NextToolCall = z.infer<typeof nextToolCallSchema>;

const DEFAULT_MODEL = "gpt-4o-mini";

export interface ResolveNextToolCallOptions {
  readonly client?: OpenAiIntentClient;
  readonly model?: string;
  readonly intentId?: string;
  readonly createdAt?: string;
  // The driver's self-described tool catalog (U1), passed in by the controller
  // because the `intent` package may not import `@handsoff/cua`. Becomes the
  // model's menu of callable tools in the prompt.
  readonly tools?: readonly DriverToolDefinition[];
}

export async function resolveNextToolCall(
  input: IntentInput,
  options: ResolveNextToolCallOptions = {},
): Promise<ResolvedIntent> {
  const createdAt = options.createdAt ?? new Date().toISOString();
  const id = options.intentId ?? "intent-llm";

  try {
    const client = options.client ?? new OpenAI();
    const completion = await client.chat.completions.parse({
      model: options.model ?? DEFAULT_MODEL,
      messages: buildNextToolCallMessages(input, options.tools ?? []),
      response_format: zodResponseFormat(nextToolCallSchema, "next_tool_call"),
    });
    const choice = completion.choices[0];
    if (!choice) {
      return blockedIntent(
        "blocked",
        input,
        id,
        createdAt,
        "The intent resolver returned no choice",
      );
    }
    if (choice.finish_reason === "length") {
      return blockedIntent(
        "clarification_required",
        input,
        id,
        createdAt,
        "The intent resolver response was truncated",
      );
    }
    if (choice.message.refusal) {
      return blockedIntent("clarification_required", input, id, createdAt, choice.message.refusal);
    }
    const parsed = choice.message.parsed as NextToolCall | null | undefined;
    if (!parsed) {
      return blockedIntent(
        "blocked",
        input,
        id,
        createdAt,
        "The intent resolver returned no parsed result",
      );
    }
    return nextToolCallToIntent(parsed, input, id, createdAt);
  } catch (caught) {
    return blockedIntent(
      "blocked",
      input,
      id,
      createdAt,
      `Intent resolver failed: ${caught instanceof Error ? caught.message : String(caught)}`,
    );
  }
}

// Map the model's next-action decision onto the `ResolvedIntent` the controller
// + UI already speak. An "act" becomes a ready intent carrying a single generic
// `tool_call` step (the loop dispatches it via the driver passthrough). Risk +
// approval are DERIVED from the tool name (never trusted from the model);
// element-semantics escalation for a commit click happens later in the loop
// from the live snapshot.
export function nextToolCallToIntent(
  next: NextToolCall,
  input: IntentInput,
  id: string,
  createdAt: string,
): ResolvedIntent {
  if (next.status === "done") {
    return {
      status: "satisfied",
      id,
      input,
      requires_approval: false,
      target_agent: "none",
      summary: next.summary?.trim() || "Goal satisfied",
      createdAt,
    };
  }
  if (next.status === "clarify") {
    return blockedIntent(
      "clarification_required",
      input,
      id,
      createdAt,
      next.reason?.trim() || "The intent resolver needs clarification",
    );
  }
  if (next.status === "blocked") {
    return blockedIntent(
      "blocked",
      input,
      id,
      createdAt,
      next.reason?.trim() || "The intent resolver blocked the goal",
    );
  }

  // status === "act": validate the tool name against the real driver surface.
  const tool = safeParseDriverTool(next.tool);
  if (!tool.success) {
    return blockedIntent(
      "blocked",
      input,
      id,
      createdAt,
      `The intent resolver chose an unknown tool: ${String(next.tool)}`,
    );
  }

  const args = parseToolArgs(next.args);
  // Provisional risk for the DISPLAY intent. The loop is authoritative: it
  // re-derives risk against the live snapshot (escalating a commit click to
  // mutating). So here we use the tool's UN-escalated base — passing an empty
  // element so a click resolves to its navigation base (reversible) rather than
  // the no-context "gate everything" default; the loop then escalates only a
  // proven commit click. Approval is still derived from risk, never the model.
  const risk = riskForToolName(tool.data, { element: {} });
  const label = next.rationale.trim() || `Call ${tool.data}`;
  return {
    status: "ready",
    id,
    input,
    intent_type: "inspect",
    referent: null,
    constraints: [],
    risk_level: risk,
    requires_approval: requiresApproval(risk),
    target_agent: "cua-driver",
    action_plan: {
      id: `${id}-plan`,
      summary: label,
      risk_level: risk,
      requires_approval: requiresApproval(risk),
      target_agent: "cua-driver",
      action_plan: [
        {
          id: `${id}-step`,
          kind: "tool_call",
          label,
          tool: tool.data,
          args,
        },
      ],
    },
    createdAt,
  };
}

// The model hands `args` back as a JSON object string (OpenAI strict rejects open
// objects on the wire); the loop wants a real record. Parse it defensively —
// null/empty/malformed JSON, or anything that isn't a plain object (array, string,
// number, null), collapses to {} so a bad payload degrades to "call with no args"
// rather than crashing the resolver. The validated parse becomes the tool_call
// step's `args`.
function parseToolArgs(raw: string | null): Record<string, unknown> {
  if (!raw) return {};
  try {
    const parsed: unknown = JSON.parse(raw);
    if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed)) {
      return {};
    }
    return parsed as Record<string, unknown>;
  } catch {
    return {};
  }
}
