import { describe, expect, it } from "vitest";

import { clarificationReasonSchema, clarificationRequestSchema } from "./clarification";

const validOption = {
  targetId: "win-1",
  label: "Slack — #general",
  confidence: 0.72,
};

const validRequest = {
  reason: "ambiguous",
  question: "Which window did you mean?",
  options: [validOption, { targetId: "win-2", label: "Chrome — GitHub #88", confidence: 0.65 }],
};

describe("clarificationReasonSchema", () => {
  it("accepts the three reasons", () => {
    for (const r of ["low_confidence", "ambiguous", "no_target"]) {
      expect(clarificationReasonSchema.safeParse(r).success).toBe(true);
    }
  });

  it("rejects an unknown reason", () => {
    expect(clarificationReasonSchema.safeParse("because").success).toBe(false);
  });
});

describe("clarificationRequestSchema", () => {
  it("parses a well-formed ambiguous request", () => {
    const parsed = clarificationRequestSchema.parse(validRequest);
    expect(parsed.options).toHaveLength(2);
    expect(parsed.options[0]?.confidence).toBe(0.72);
  });

  it("allows empty options (no_target — nothing to pick)", () => {
    const r = clarificationRequestSchema.safeParse({
      reason: "no_target",
      question: "Couldn't find a target — re-point.",
      options: [],
    });
    expect(r.success).toBe(true);
  });

  it("rejects an empty question", () => {
    expect(clarificationRequestSchema.safeParse({ ...validRequest, question: "" }).success).toBe(
      false,
    );
  });

  it("rejects an option confidence outside [0,1]", () => {
    const bad = { ...validRequest, options: [{ ...validOption, confidence: 1.4 }] };
    expect(clarificationRequestSchema.safeParse(bad).success).toBe(false);
  });

  it("rejects an option without a label", () => {
    const bad = { ...validRequest, options: [{ targetId: "x", confidence: 0.5 }] };
    expect(clarificationRequestSchema.safeParse(bad).success).toBe(false);
  });
});
