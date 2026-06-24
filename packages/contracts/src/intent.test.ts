import { describe, expect, it } from "vitest";

import { safeParseResolvedIntent } from "./intent";
import type { IntentInput, ResolvedIntent } from "./intent";

type ReadyIntent = Extract<ResolvedIntent, { status: "ready" }>;

function input(overrides: Partial<IntentInput> = {}): IntentInput {
  const surface = {
    id: "surface-1",
    title: "Notes",
    app: "Notes",
    pid: 42,
    windowId: 7,
    availability: "available" as const,
    accessStatus: "accessible" as const,
  };

  return {
    sessionId: "session-1",
    speech: {
      finalTranscript: {
        kind: "final",
        text: "click there",
        confidence: 0.95,
        latencyMs: 110,
        receivedAt: 1_719_000_000,
      },
    },
    pointingEvidence: [
      {
        source: "cursor",
        confidence: 0.91,
        strategy: "active-window-current-cursor",
        surface,
        cursor: { x: 100, y: 120 },
      },
    ],
    surfaceCandidates: [surface],
    ...overrides,
  };
}

function readyIntent(overrides: Partial<ReadyIntent> = {}): ReadyIntent {
  const baseInput = input();
  const target = { surface: baseInput.surfaceCandidates[0]!, elementIndex: 0 };

  return {
    status: "ready",
    id: "intent-1",
    input: baseInput,
    intent_type: "click",
    referent: { id: "surface-1", source: "fusion", confidence: 0.91 },
    constraints: [],
    risk_level: "mutating",
    requires_approval: true,
    target_agent: "cua-driver",
    action_plan: {
      id: "plan-1",
      summary: "Click the selected target",
      risk_level: "mutating",
      requires_approval: true,
      target_agent: "cua-driver",
      action_plan: [
        { id: "step-1", kind: "click_element", label: "Click selected target", target },
      ],
    },
    createdAt: "2026-06-22T12:00:00.000Z",
    ...overrides,
  };
}

describe("resolved intent contract", () => {
  it("accepts final transcript plus current-cursor pointing evidence", () => {
    const result = safeParseResolvedIntent(readyIntent());

    expect(result.success).toBe(true);
  });

  it("accepts goal-session observations on next-action inputs", () => {
    const observed = input({
      goalSession: {
        goal: "dump this text into Notes",
        tick: 1,
        observations: [
          {
            tick: 0,
            capturedAt: "2026-06-22T12:00:00.000Z",
            windows: [input().surfaceCandidates[0]!],
            state: {
              surface: input().surfaceCandidates[0]!,
              capturedAt: "2026-06-22T12:00:00.000Z",
              elementCount: 1,
              elements: [{ id: "notes-body", index: 0, role: "text" }],
            },
            previousAction: {
              actionId: "plan-open-notes",
              result: { status: "succeeded", summary: "Opened Notes" },
            },
          },
        ],
      },
    });

    const result = safeParseResolvedIntent(readyIntent({ input: observed }));

    expect(result.success).toBe(true);
  });

  it("rejects missing pointing evidence", () => {
    const result = safeParseResolvedIntent(readyIntent({ input: input({ pointingEvidence: [] }) }));

    expect(result.success).toBe(false);
  });

  it("accepts clarification states without an action plan", () => {
    const result = safeParseResolvedIntent({
      status: "clarification_required",
      id: "intent-2",
      input: input(),
      constraints: [],
      requires_approval: false,
      target_agent: "none",
      reason: "No accessible target was found",
      createdAt: "2026-06-22T12:00:00.000Z",
    } satisfies ResolvedIntent);

    expect(result.success).toBe(true);
  });

  it("accepts a satisfied terminal intent with no action plan", () => {
    const result = safeParseResolvedIntent({
      status: "satisfied",
      id: "intent-done",
      input: input(),
      requires_approval: false,
      target_agent: "none",
      summary: "Notes now contains the dictated idea",
      createdAt: "2026-06-22T12:00:00.000Z",
    } satisfies ResolvedIntent);

    expect(result.success).toBe(true);
  });
});
