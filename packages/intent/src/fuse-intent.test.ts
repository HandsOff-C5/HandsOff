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

  it("attaches a structured low_confidence clarification (#36)", () => {
    const intent = fuseIntent(
      input("click there", {
        pointingEvidence: [
          { source: "cursor", confidence: 0.2, strategy: "active-window-current-cursor" },
        ],
      }),
    );

    expect(intent.status).toBe("clarification_required");
    if (intent.status !== "clarification_required") throw new Error("expected clarification");
    expect(intent.clarification?.reason).toBe("low_confidence");
  });

  it("asks which target when two candidates are too close (#36)", () => {
    const slack = surface({ id: "win-slack", title: "#general", app: "Slack" });
    const chrome = surface({ id: "win-chrome", title: "GitHub #88", app: "Chrome" });
    const intent = fuseIntent(
      input("click there", {
        pointingEvidence: [
          { source: "gesture", confidence: 0.8, strategy: "wrist-ray", surface: slack },
          { source: "gaze", confidence: 0.75, strategy: "head-pose", surface: chrome },
        ],
        surfaceCandidates: [slack, chrome],
      }),
    );

    expect(intent.status).toBe("clarification_required");
    if (intent.status !== "clarification_required") throw new Error("expected clarification");
    expect(intent.clarification?.reason).toBe("ambiguous");
    expect(intent.clarification?.options).toHaveLength(2);
  });

  it("turns open-app-and-type commands into launch plus type steps without pointing candidates", () => {
    const intent = fuseIntent(
      input("Open TextEdit and type hello goodbye", {
        pointingEvidence: [{ source: "head", confidence: 0, strategy: "head-neighborhood-empty" }],
        surfaceCandidates: [],
      }),
      { createdAt: "2026-06-22T12:00:00.000Z" },
    );

    expect(intent).toMatchObject({
      status: "ready",
      action_plan: {
        action_plan: [
          { kind: "launch_app", appName: "TextEdit" },
          { kind: "type_text", text: "hello goodbye", target: { surface: { app: "TextEdit" } } },
        ],
      },
    });
  });
});
