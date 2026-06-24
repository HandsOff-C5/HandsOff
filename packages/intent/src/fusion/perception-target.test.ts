import { describe, expect, it } from "vitest";

import type { IntentInput } from "@handsoff/contracts";

import { fuseIntent } from "../fuse-intent";
import goldens from "../fixtures/perception-fusion/goldens.json";
import { fusePerceptionTarget, type FusePerceptionTargetInput } from "./perception-target";

type Golden = {
  name: string;
  input: FusePerceptionTargetInput;
  expected: ReturnType<typeof fusePerceptionTarget>;
  intent: {
    status: "ready" | "clarification_required";
    reason?: string;
  };
};

const cases = goldens as Golden[];

function intentInput(selection: ReturnType<typeof fusePerceptionTarget>): IntentInput {
  return {
    sessionId: "session-1",
    speech: {
      finalTranscript: {
        kind: "final",
        text: "click that",
        confidence: 0.95,
        latencyMs: 100,
        receivedAt: 1,
      },
    },
    pointingEvidence: [...selection.pointingEvidence],
    surfaceCandidates: [...selection.surfaceCandidates],
  };
}

describe("perception target fusion", () => {
  it.each(cases)("$name", (golden) => {
    const selection = fusePerceptionTarget(golden.input);

    expect(selection).toEqual(golden.expected);

    const intent = fuseIntent(intentInput(selection), {
      intentId: "intent-click",
      planId: "plan-click",
      createdAt: "2026-06-22T12:00:00.000Z",
    });

    expect(intent.status).toBe(golden.intent.status);
    if (golden.intent.reason) {
      expect(intent).toMatchObject({
        status: "clarification_required",
        clarification: { reason: golden.intent.reason },
      });
    }
  });
});
