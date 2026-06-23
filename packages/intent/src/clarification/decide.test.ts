import { clarificationRequestSchema } from "@handsoff/contracts";
import { describe, expect, it } from "vitest";

import {
  decideClarification,
  DEFAULT_CLARIFICATION_POLICY,
  type ClarificationCandidate,
} from "./decide";

const cand = (
  targetId: string,
  confidence: number,
  label = targetId,
): ClarificationCandidate => ({ targetId, label, confidence });

const policy = { minConfidence: 0.6, ambiguityMargin: 0.1 };

describe("decideClarification", () => {
  it("acts on a single confident candidate", () => {
    expect(decideClarification([cand("a", 0.9)], policy)).toEqual({
      kind: "act",
      targetId: "a",
    });
  });

  it("acts on a clear winner (top above threshold, second far below)", () => {
    const d = decideClarification([cand("a", 0.85), cand("b", 0.4)], policy);
    expect(d.kind).toBe("act");
    if (d.kind === "act") expect(d.targetId).toBe("a");
  });

  it("clarifies low_confidence when the best candidate is below threshold", () => {
    const d = decideClarification([cand("a", 0.5)], policy);
    expect(d.kind).toBe("clarify");
    if (d.kind !== "clarify") throw new Error("expected clarify");
    expect(d.request.reason).toBe("low_confidence");
    expect(d.request.options.map((o) => o.targetId)).toEqual(["a"]);
  });

  it("clarifies ambiguous when the top two are within the margin", () => {
    const d = decideClarification([cand("a", 0.8), cand("b", 0.75)], policy);
    expect(d.kind).toBe("clarify");
    if (d.kind !== "clarify") throw new Error("expected clarify");
    expect(d.request.reason).toBe("ambiguous");
    expect(d.request.options).toHaveLength(2);
  });

  it("clarifies no_target with empty options when there are no candidates", () => {
    const d = decideClarification([], policy);
    expect(d.kind).toBe("clarify");
    if (d.kind !== "clarify") throw new Error("expected clarify");
    expect(d.request.reason).toBe("no_target");
    expect(d.request.options).toEqual([]);
  });

  it("low_confidence takes precedence over ambiguity (best is too weak to trust)", () => {
    const d = decideClarification([cand("a", 0.4), cand("b", 0.38)], policy);
    if (d.kind !== "clarify") throw new Error("expected clarify");
    expect(d.request.reason).toBe("low_confidence");
  });

  it("sorts options by confidence descending", () => {
    const d = decideClarification([cand("a", 0.7), cand("b", 0.78), cand("c", 0.72)], {
      minConfidence: 0.6,
      ambiguityMargin: 0.2,
    });
    if (d.kind !== "clarify") throw new Error("expected clarify");
    expect(d.request.options.map((o) => o.targetId)).toEqual(["b", "c", "a"]);
  });

  it("carries label and calibrated confidence into the options", () => {
    const d = decideClarification([cand("win-1", 0.5, "Slack — #general")], policy);
    if (d.kind !== "clarify") throw new Error("expected clarify");
    expect(d.request.options[0]).toMatchObject({
      targetId: "win-1",
      label: "Slack — #general",
      confidence: 0.5,
    });
  });

  it("produces a contract-valid ClarificationRequest", () => {
    const d = decideClarification([cand("a", 0.8), cand("b", 0.78)], policy);
    if (d.kind !== "clarify") throw new Error("expected clarify");
    expect(clarificationRequestSchema.safeParse(d.request).success).toBe(true);
  });

  it("exposes a default policy", () => {
    expect(DEFAULT_CLARIFICATION_POLICY.minConfidence).toBeGreaterThan(0);
    expect(DEFAULT_CLARIFICATION_POLICY.ambiguityMargin).toBeGreaterThan(0);
  });
});
