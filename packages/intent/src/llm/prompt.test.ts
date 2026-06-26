import type { DriverToolDefinition, IntentInput, SurfaceSnapshot } from "@handsoff/contracts";
import { describe, expect, it } from "vitest";

import { buildNextToolCallMessages, buildResolveIntentMessages } from "./prompt";

// Prompt presentation of bound referents + per-candidate pointing confidence
// (KD5/U7). The temporal binder emits each deictic word as `fusion`
// PointingEvidence stamped `temporal-bind:<word>@<ts>`; the next-tool-call prompt
// must surface those bound referents and join the confidence/source onto each
// candidate, so the model acts on the deixis instead of guessing one target.

function surface(overrides: Partial<SurfaceSnapshot> = {}): SurfaceSnapshot {
  return {
    id: "win-notes",
    title: "Notes",
    app: "Notes",
    pid: 11,
    windowId: 1,
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
        text: "type Laura in this and hello in that",
        confidence: 0.95,
        latencyMs: 100,
        receivedAt: 1,
      },
    },
    pointingEvidence: [{ source: "head", confidence: 0.5, strategy: "head-neighborhood" }],
    surfaceCandidates: [surface()],
    ...overrides,
  };
}

const tools: readonly DriverToolDefinition[] = [
  { name: "type_text", description: "Type into the focused field.", inputSchema: null },
];

const notes = surface({ id: "win-notes", title: "Notes", app: "Notes" });
const slack = surface({ id: "win-slack", title: "Slack", app: "Slack", pid: 22, windowId: 2 });

describe("buildNextToolCallMessages — bound referents (U7)", () => {
  it("serializes each deictic word's bound surface + confidence in boundReferents", () => {
    const messages = buildNextToolCallMessages(
      input({
        pointingEvidence: [
          {
            source: "fusion",
            confidence: 0.85,
            strategy: "temporal-bind:this@1100",
            surface: notes,
          },
          {
            source: "fusion",
            confidence: 0.72,
            strategy: "temporal-bind:that@5100",
            surface: slack,
          },
        ],
        surfaceCandidates: [notes, slack],
      }),
      tools,
    );
    const payload = JSON.parse(messages[1]!.content);

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
        confidence: 0.72,
        strategy: "temporal-bind:that@5100",
      },
    ]);
  });

  it("joins pointing confidence + source onto each candidate surface", () => {
    const messages = buildNextToolCallMessages(
      input({
        pointingEvidence: [
          {
            source: "fusion",
            confidence: 0.85,
            strategy: "temporal-bind:this@1100",
            surface: notes,
          },
          { source: "gesture", confidence: 0.4, strategy: "wrist-ray-position", surface: slack },
        ],
        surfaceCandidates: [notes, slack],
      }),
      tools,
    );
    const payload = JSON.parse(messages[1]!.content);

    expect(payload.candidateSurfaces).toEqual([
      expect.objectContaining({ rank: 1, id: "win-notes", confidence: 0.85, source: "fusion" }),
      expect.objectContaining({ rank: 2, id: "win-slack", confidence: 0.4, source: "gesture" }),
    ]);
  });

  it("takes the strongest evidence when a surface has several pointing entries", () => {
    const messages = buildNextToolCallMessages(
      input({
        pointingEvidence: [
          { source: "head", confidence: 0.3, strategy: "head-neighborhood", surface: notes },
          {
            source: "fusion",
            confidence: 0.9,
            strategy: "temporal-bind:this@1100",
            surface: notes,
          },
        ],
        surfaceCandidates: [notes],
      }),
      tools,
    );
    const payload = JSON.parse(messages[1]!.content);
    // 0.9 (fusion) beats 0.3 (head) for the same surface.
    expect(payload.candidateSurfaces[0]).toMatchObject({ confidence: 0.9, source: "fusion" });
  });

  it("leaves boundReferents empty and candidate confidence null when nothing is bound", () => {
    const messages = buildNextToolCallMessages(input(), tools);
    const payload = JSON.parse(messages[1]!.content);
    expect(payload.boundReferents).toEqual([]);
    // The single head candidate has no surface-carrying evidence referencing it
    // (head-neighborhood here has no surface), so confidence/source are null.
    expect(payload.candidateSurfaces[0]).toMatchObject({ confidence: null, source: null });
  });
});

// Regression: the legacy 6-kind prompt must stay weightless (its eval golden and
// the no-raw-camera-data contract depend on it) — bound referents are only added
// to the autonomous-loop (next-tool-call) prompt.
describe("buildResolveIntentMessages — unchanged by U7", () => {
  it("does not add boundReferents to the legacy prompt", () => {
    const messages = buildResolveIntentMessages(
      input({
        pointingEvidence: [
          {
            source: "fusion",
            confidence: 0.85,
            strategy: "temporal-bind:this@1100",
            surface: notes,
          },
        ],
        surfaceCandidates: [notes],
      }),
    );
    const payload = JSON.parse(messages[1]!.content);
    expect(payload.boundReferents).toBeUndefined();
    // The candidate list stays weightless in the legacy prompt.
    expect(payload.candidateSurfaces[0]).not.toHaveProperty("confidence");
  });
});
