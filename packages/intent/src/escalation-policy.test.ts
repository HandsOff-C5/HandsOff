import { describe, expect, it } from "vitest";

import {
  routeByConfidence,
  DEFAULT_ESCALATION_THRESHOLDS,
  type EscalationRoute,
} from "./escalation-policy";

describe("routeByConfidence — the CUA-5 threshold band", () => {
  it("acts on its own when confidence is at or above the act threshold (0.7)", () => {
    expect(routeByConfidence(0.95)).toBe<EscalationRoute>("act");
    expect(routeByConfidence(0.7)).toBe<EscalationRoute>("act");
  });

  it("escalates to the agent in the middle band (0.4 ≤ conf < 0.7)", () => {
    expect(routeByConfidence(0.69)).toBe<EscalationRoute>("escalate_to_agent");
    expect(routeByConfidence(0.5)).toBe<EscalationRoute>("escalate_to_agent");
    expect(routeByConfidence(0.4)).toBe<EscalationRoute>("escalate_to_agent");
  });

  it("clarifies when confidence is below the escalate floor (0.4)", () => {
    expect(routeByConfidence(0.39)).toBe<EscalationRoute>("clarify");
    expect(routeByConfidence(0)).toBe<EscalationRoute>("clarify");
  });

  it("clamps an out-of-range or NaN confidence to the safe ends", () => {
    expect(routeByConfidence(1.5)).toBe<EscalationRoute>("act");
    expect(routeByConfidence(-0.2)).toBe<EscalationRoute>("clarify");
    // A NaN signal must never silently act — it routes to the safest branch.
    expect(routeByConfidence(Number.NaN)).toBe<EscalationRoute>("clarify");
  });

  it("respects custom thresholds (band tuning)", () => {
    const thresholds = { actAt: 0.8, escalateAt: 0.3 };
    expect(routeByConfidence(0.75, thresholds)).toBe<EscalationRoute>("escalate_to_agent");
    expect(routeByConfidence(0.85, thresholds)).toBe<EscalationRoute>("act");
    expect(routeByConfidence(0.25, thresholds)).toBe<EscalationRoute>("clarify");
  });

  it("exposes the agreed defaults (0.7 act / 0.4 escalate)", () => {
    expect(DEFAULT_ESCALATION_THRESHOLDS).toEqual({ actAt: 0.7, escalateAt: 0.4 });
  });
});
