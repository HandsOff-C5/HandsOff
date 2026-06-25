import { describe, expect, it, vi } from "vitest";

import {
  resolvedIntentSchema,
  type DriverToolDefinition,
  type IntentInput,
  type SurfaceSnapshot,
} from "@handsoff/contracts";

import { buildNextToolCallMessages } from "./prompt";
import { nextToolCallToIntent, resolveNextToolCall, type NextToolCall } from "./next-tool-call";
import type { OpenAiIntentClient } from "./openai-resolver";

// A mock parsed choice carrying the next-tool-call schema's parsed payload (the
// SDK's `parsed` is the response_format's type — NextToolCall here).
type NextToolCallChoice = {
  finish_reason: string | null;
  message: { parsed?: NextToolCall | null; refusal?: string | null };
};

function surface(overrides: Partial<SurfaceSnapshot> = {}): SurfaceSnapshot {
  return {
    id: "notes:1",
    title: "Quick Note",
    app: "Notes",
    pid: 42,
    windowId: 7,
    availability: "available",
    accessStatus: "accessible",
    ...overrides,
  };
}

function input(overrides: Partial<IntentInput> = {}): IntentInput {
  return {
    sessionId: "session-1",
    speech: {
      finalTranscript: {
        kind: "final",
        text: "scroll down to find Boogie Woogie",
        confidence: 0.95,
        latencyMs: 100,
        receivedAt: 1,
      },
    },
    pointingEvidence: [{ source: "head", confidence: 0.9, strategy: "head-neighborhood" }],
    surfaceCandidates: [surface()],
    ...overrides,
  };
}

const tools: readonly DriverToolDefinition[] = [
  {
    name: "scroll",
    description: "Scroll the target pid's focused region.",
    inputSchema: {
      type: "object",
      required: ["pid", "direction"],
      properties: { pid: { type: "integer" }, direction: { type: "string" } },
    },
  },
  { name: "get_window_state", description: "Snapshot a window's AX tree.", inputSchema: null },
];

function next(overrides: Partial<NextToolCall> = {}): NextToolCall {
  return {
    status: "act",
    tool: "scroll",
    args: { pid: 42, window_id: 7, direction: "down", by: "page", amount: 3 },
    rationale: "Scroll the list to reveal hidden rows",
    summary: null,
    reason: null,
    ...overrides,
  };
}

function clientWith(choice: NextToolCallChoice) {
  const parse = vi.fn().mockResolvedValue({ choices: [choice] });
  const client: OpenAiIntentClient = { chat: { completions: { parse } } };
  return { client, parse };
}

describe("resolveNextToolCall", () => {
  it("maps an act decision to a ready intent carrying a tool_call step over the full surface", async () => {
    const { client, parse } = clientWith({ finish_reason: "stop", message: { parsed: next() } });

    const resolved = await resolveNextToolCall(input(), {
      client,
      tools,
      createdAt: "2026-06-22T12:00:00.000Z",
    });

    expect(resolvedIntentSchema.safeParse(resolved).success).toBe(true);
    expect(resolved).toMatchObject({
      status: "ready",
      target_agent: "cua-driver",
      // scroll is read_only → no approval, and it auto-runs.
      risk_level: "read_only",
      requires_approval: false,
      action_plan: {
        action_plan: [
          {
            kind: "tool_call",
            tool: "scroll",
            args: { pid: 42, window_id: 7, direction: "down" },
          },
        ],
      },
    });
    expect(parse).toHaveBeenCalledWith(expect.objectContaining({ model: "gpt-4o-mini" }));
  });

  it("uses the un-escalated tool base for the display intent; the loop escalates commits", async () => {
    const { client } = clientWith({
      finish_reason: "stop",
      message: {
        parsed: next({ tool: "click", args: { pid: 42, window_id: 7, element_index: 3 } }),
      },
    });

    // The display intent carries the click's NAVIGATION base (reversible) so the
    // loop stays authoritative — it re-derives risk from the live snapshot and
    // escalates only a proven commit click (Send/Delete) to mutating. Risk is
    // tool-derived here, never the model's claim.
    await expect(resolveNextToolCall(input(), { client, tools })).resolves.toMatchObject({
      status: "ready",
      risk_level: "reversible",
      requires_approval: false,
    });
  });

  it("blocks a hallucinated tool name that is not on the driver surface", async () => {
    const { client } = clientWith({
      finish_reason: "stop",
      message: { parsed: next({ tool: "format_disk", args: {} }) },
    });

    await expect(resolveNextToolCall(input(), { client, tools })).resolves.toMatchObject({
      status: "blocked",
      reason: "The intent resolver chose an unknown tool: format_disk",
    });
  });

  it("maps done → satisfied and clarify/blocked → their statuses", async () => {
    const done = await resolveNextToolCall(input(), {
      client: clientWith({
        finish_reason: "stop",
        message: { parsed: next({ status: "done", tool: null, args: null, summary: "Found it" }) },
      }).client,
      tools,
    });
    expect(done).toMatchObject({ status: "satisfied", summary: "Found it" });

    const clarify = await resolveNextToolCall(input(), {
      client: clientWith({
        finish_reason: "stop",
        message: {
          parsed: next({ status: "clarify", tool: null, args: null, reason: "Which window?" }),
        },
      }).client,
      tools,
    });
    expect(clarify).toMatchObject({ status: "clarification_required", reason: "Which window?" });
  });

  it("turns a refusal into a recoverable clarification and an error into blocked", async () => {
    const refusal = await resolveNextToolCall(input(), {
      client: clientWith({ finish_reason: "stop", message: { refusal: "I can't do that." } })
        .client,
      tools,
    });
    expect(refusal).toMatchObject({ status: "clarification_required", reason: "I can't do that." });

    const failing: OpenAiIntentClient = {
      chat: {
        completions: {
          parse: vi.fn().mockRejectedValue(new Error("network down")),
        },
      },
    };
    const blocked = await resolveNextToolCall(input(), { client: failing, tools });
    expect(blocked).toMatchObject({
      status: "blocked",
      reason: "Intent resolver failed: network down",
    });
  });
});

describe("nextToolCallToIntent", () => {
  it("defaults missing args to an empty object on the tool_call step", () => {
    const resolved = nextToolCallToIntent(
      next({ tool: "list_windows", args: null }),
      input(),
      "intent-x",
      "2026-06-22T12:00:00.000Z",
    );
    expect(resolved).toMatchObject({
      status: "ready",
      action_plan: { action_plan: [{ kind: "tool_call", tool: "list_windows", args: {} }] },
    });
  });
});

describe("buildNextToolCallMessages", () => {
  it("sends the goal, live snapshot, loop memory, candidates, and the tool menu", () => {
    const messages = buildNextToolCallMessages(
      input({
        goalSession: {
          goal: "scroll to find Boogie Woogie",
          tick: 1,
          observations: [
            {
              tick: 1,
              capturedAt: "2026-06-22T12:00:01.000Z",
              windows: [surface()],
              state: {
                surface: surface(),
                capturedAt: "2026-06-22T12:00:01.000Z",
                elementCount: 1,
                elements: [{ id: "row-1", index: 5, role: "AXRow", label: "Boogie" }],
              },
              previousAction: {
                actionId: "intent-x-plan",
                result: { status: "succeeded", summary: "scrolled" },
              },
            },
          ],
        },
      }),
      tools,
    );
    const payload = JSON.parse(messages[1]!.content);

    expect(payload.goal).toBe("scroll to find Boogie Woogie");
    expect(payload.latestSnapshot).toMatchObject({
      focusedWindow: { id: "notes:1", pid: 42, windowId: 7 },
      elements: [{ index: 5, role: "AXRow", label: "Boogie" }],
    });
    expect(payload.recentResults).toEqual([{ tick: 1, status: "succeeded", detail: "scrolled" }]);
    // The full tool surface menu reaches the model.
    expect(payload.availableTools).toEqual([
      {
        name: "scroll",
        description: "Scroll the target pid's focused region.",
        parameters: {
          type: "object",
          required: ["pid", "direction"],
          properties: { pid: { type: "integer" }, direction: { type: "string" } },
        },
      },
      { name: "get_window_state", description: "Snapshot a window's AX tree.", parameters: null },
    ]);
    // No binding on a plain head utterance → empty boundReferents (regression
    // guard that the field is always present, not undefined).
    expect(payload.boundReferents).toEqual([]);
  });

  // KD5: the model previously got a weightless candidate list and punted with
  // "ambiguous target". Now the temporally bound deictic referents (fusion
  // evidence the binder emitted, U6/U7) and per-candidate pointing confidence/
  // source reach the model so it can act on the deixis.
  it("presents bound deictic referents + per-candidate confidence/source to the model", () => {
    const notes = surface({ id: "win-notes", title: "Notes", app: "Notes" });
    const slack = surface({ id: "win-slack", title: "Slack", app: "Slack" });
    const messages = buildNextToolCallMessages(
      input({
        speech: {
          finalTranscript: {
            kind: "final",
            text: "type Laura in this and hello in that",
            confidence: 0.95,
            latencyMs: 100,
            receivedAt: 1,
          },
        },
        // Two deictic words bound to two different surfaces by the temporal binder
        // (Notes ← "this" @1100, Slack ← "that" @5100), exactly as the controller
        // prepends them.
        pointingEvidence: [
          {
            source: "fusion",
            confidence: 0.85,
            strategy: "temporal-bind:this@1100",
            surface: notes,
          },
          {
            source: "fusion",
            confidence: 0.8,
            strategy: "temporal-bind:that@5100",
            surface: slack,
          },
        ],
        surfaceCandidates: [notes, slack],
      }),
      tools,
    );
    const payload = JSON.parse(messages[1]!.content);

    // Both deictics resolved to distinct surfaces, in order, with the word + confidence.
    expect(payload.boundReferents).toEqual([
      {
        word: "this",
        surfaceId: "win-notes",
        app: "Notes",
        title: "Notes",
        confidence: 0.85,
        strategy: "temporal-bind:this@1100",
      },
      {
        word: "that",
        surfaceId: "win-slack",
        app: "Slack",
        title: "Slack",
        confidence: 0.8,
        strategy: "temporal-bind:that@5100",
      },
    ]);
    // Each candidate now carries the pointing confidence + the modality behind it.
    expect(payload.candidateSurfaces).toEqual([
      expect.objectContaining({ id: "win-notes", confidence: 0.85, source: "fusion" }),
      expect.objectContaining({ id: "win-slack", confidence: 0.8, source: "fusion" }),
    ]);
  });
});
