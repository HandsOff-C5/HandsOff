import { describe, expect, it } from "vitest";

import { fuseIntent } from "../fuse-intent";
import goldens from "./voice-cua-goldens.json";
import type {
  IntentInput,
  ResolvedIntent,
  SurfaceAvailability,
  SurfaceSnapshot,
} from "@handsoff/contracts";

type EvalRecord = {
  status: ResolvedIntent["status"];
  intent_type?: string;
  risk_level?: string;
  requires_approval: boolean;
  target_agent: string;
  referentId?: string;
  reason?: string;
  actionKinds: readonly string[];
};

function surface(availability: SurfaceAvailability = "available"): SurfaceSnapshot {
  return {
    id: "surface-1",
    title: "Notes",
    app: "Notes",
    pid: 42,
    windowId: 7,
    availability,
    accessStatus: availability === "available" ? "accessible" : "unknown",
  };
}

function input(transcript: string, availability?: SurfaceAvailability): IntentInput {
  const selected = surface(availability);
  return {
    sessionId: "session-1",
    speech: {
      finalTranscript: {
        kind: "final",
        text: transcript,
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
  };
}

function project(intent: ResolvedIntent): EvalRecord {
  return {
    status: intent.status,
    intent_type: "intent_type" in intent ? intent.intent_type : undefined,
    risk_level: "risk_level" in intent ? intent.risk_level : undefined,
    requires_approval: intent.requires_approval,
    target_agent: intent.target_agent,
    referentId: "referent" in intent ? intent.referent.id : undefined,
    reason: "reason" in intent ? intent.reason : undefined,
    actionKinds:
      "action_plan" in intent ? intent.action_plan.action_plan.map((step) => step.kind) : [],
  };
}

describe("voice CUA golden evals", () => {
  it.each(goldens)("$name", (golden) => {
    const records = new Map<string, EvalRecord>();
    const resolved = fuseIntent(
      input(golden.transcript, golden.surfaceAvailability as SurfaceAvailability | undefined),
      {
        intentId: `intent-${golden.name}`,
        planId: `plan-${golden.name}`,
        createdAt: "2026-06-22T12:00:00.000Z",
      },
    );

    records.set(golden.name, project(resolved));

    expect(records.get(golden.name)).toEqual(golden.expected);
  });
});
