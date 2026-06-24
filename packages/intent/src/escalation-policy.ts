// CUA-5 routing policy (Hirom's call, 2026-06-23): a confidence *band* decides
// what HandsOff does with a fused request, rather than a single act/don't-act
// cut. High confidence acts on its own; a middle band hands off to the AX CUA
// agent loop (still approval-gated per mutating action); low confidence asks a
// clarifying question instead of guessing. This is a pure primitive — the live
// fuse-intent seam (#88, Naama) consumes it; it does not modify that seam.
export type EscalationRoute = "act" | "escalate_to_agent" | "clarify";

export interface EscalationThresholds {
  // At or above this fused confidence, act directly.
  actAt: number;
  // At or above this (but below actAt), escalate to the CUA agent.
  escalateAt: number;
}

export const DEFAULT_ESCALATION_THRESHOLDS: EscalationThresholds = {
  actAt: 0.7,
  escalateAt: 0.4,
};

// Route a fused confidence to act / escalate / clarify. A NaN or out-of-range
// confidence is treated conservatively: NaN and anything below the escalate
// floor route to `clarify` (never silently act), while a value above the act
// threshold routes to `act` by the `>=` comparison.
export function routeByConfidence(
  confidence: number,
  thresholds: EscalationThresholds = DEFAULT_ESCALATION_THRESHOLDS,
): EscalationRoute {
  if (Number.isNaN(confidence)) return "clarify";
  if (confidence >= thresholds.actAt) return "act";
  if (confidence >= thresholds.escalateAt) return "escalate_to_agent";
  return "clarify";
}
