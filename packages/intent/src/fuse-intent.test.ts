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

  it("escalates to the agent when fused confidence lands in the band (CUA-5)", () => {
    const grounded = surface();
    const intent = fuseIntent(
      input("click there", {
        pointingEvidence: [
          {
            source: "cursor",
            confidence: 0.55,
            strategy: "active-window-current-cursor",
            surface: grounded,
          },
        ],
        surfaceCandidates: [grounded],
      }),
    );

    expect(intent.status).toBe("escalate_to_agent");
    if (intent.status !== "escalate_to_agent") throw new Error("expected escalate_to_agent");
    // It carries the grounded window + the confidence that triggered the hand-off.
    expect(intent.surface.app).toBe("Notes");
    expect(intent.fusedConfidence).toBeCloseTo(0.55);
    expect(intent.target_agent).toBe("cua-driver");
  });

  it("acts directly above the band, escalates inside it, clarifies below it", () => {
    const make = (confidence: number) => {
      const s = surface();
      return fuseIntent(
        input("click there", {
          pointingEvidence: [
            { source: "cursor", confidence, strategy: "active-window-current-cursor", surface: s },
          ],
          surfaceCandidates: [s],
        }),
      ).status;
    };
    expect(make(0.85)).toBe("ready");
    expect(make(0.45)).toBe("escalate_to_agent");
    expect(make(0.3)).toBe("clarification_required");
  });

  it("honors custom escalation thresholds", () => {
    const grounded = surface();
    const intent = fuseIntent(
      input("click there", {
        pointingEvidence: [
          {
            source: "cursor",
            confidence: 0.65,
            strategy: "active-window-current-cursor",
            surface: grounded,
          },
        ],
        surfaceCandidates: [grounded],
      }),
      { escalationThresholds: { actAt: 0.6, escalateAt: 0.3 } },
    );
    // 0.65 >= custom actAt 0.6 → acts instead of escalating.
    expect(intent.status).toBe("ready");
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

  it("turns a bare 'open Cursor' into a single launch step, no pointing needed (golden flow)", () => {
    const intent = fuseIntent(
      input("open Cursor", {
        pointingEvidence: [{ source: "head", confidence: 0, strategy: "head-neighborhood-empty" }],
        surfaceCandidates: [],
      }),
      { intentId: "intent-open", planId: "plan-open", createdAt: "2026-06-22T12:00:00.000Z" },
    );

    expect(intent).toMatchObject({
      status: "ready",
      intent_type: "launch",
      risk_level: "reversible",
      requires_approval: false,
      target_agent: "cua-driver",
      referent: { id: "app:cursor", source: "fusion", confidence: 1 },
      action_plan: { action_plan: [{ kind: "launch_app", appName: "Cursor" }] },
    });
    if (intent.status !== "ready") throw new Error("expected ready");
    expect(intent.action_plan.action_plan).toHaveLength(1);
  });
});
