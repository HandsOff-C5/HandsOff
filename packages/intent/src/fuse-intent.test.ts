import { describe, expect, it } from "vitest";

import { fuseIntent } from "./fuse-intent";
import type { IntentInput, SurfaceSnapshot } from "@handsoff/contracts";

function surface(overrides: Partial<SurfaceSnapshot> = {}): SurfaceSnapshot {
  return {
    id: "surface-1",
    title: "Notes",
    app: "Notes",
    pid: 42,
    windowId: 7,
    availability: "available",
    accessStatus: "accessible",
    ...overrides,
  };
}

function input(text = "click there", overrides: Partial<IntentInput> = {}): IntentInput {
  const selected = surface();
  return {
    sessionId: "session-1",
    speech: {
      finalTranscript: {
        kind: "final",
        text,
        confidence: 0.95,
        latencyMs: 100,
        receivedAt: 1,
      },
    },
    pointingEvidence: [
      {
        source: "cursor",
        confidence: 0.9,
        strategy: "active-window-current-cursor",
        surface: selected,
        cursor: { x: 10, y: 20 },
      },
    ],
    surfaceCandidates: [selected],
    ...overrides,
  };
}

describe("intent fusion", () => {
  it("fuses final transcript and cursor evidence into an approvable click plan", () => {
    const intent = fuseIntent(input(), {
      intentId: "intent-click",
      planId: "plan-click",
      createdAt: "2026-06-22T12:00:00.000Z",
    });

    expect(intent).toMatchObject({
      status: "ready",
      intent_type: "click",
      referent: { id: "surface-1", source: "fusion", confidence: 0.9 },
      risk_level: "mutating",
      requires_approval: true,
      target_agent: "cua-driver",
      action_plan: { action_plan: [{ kind: "click_element" }] },
    });
  });

  it("requires clarification when confidence is too low", () => {
    const intent = fuseIntent(
      input("click there", {
        pointingEvidence: [
          { source: "cursor", confidence: 0.2, strategy: "active-window-current-cursor" },
        ],
      }),
    );

    expect(intent).toMatchObject({
      status: "clarification_required",
      reason: "Pointing confidence is too low",
      target_agent: "none",
    });
  });

  it("blocks unsupported commands", () => {
    const intent = fuseIntent(input("send it"));

    expect(intent).toMatchObject({
      status: "blocked",
      reason: "Unsupported voice command",
      target_agent: "none",
    });
  });
});
