import type {
  ClarificationOption,
  ClarificationReason,
  ClarificationRequest,
  SurfaceSnapshot,
} from "@handsoff/contracts";

// Clarification decision policy (#36). Pure: given the referent candidates (with
// CALIBRATED confidence, #100) and the policy thresholds, decide whether the
// engine can act or must ask. AD5: clarify below threshold, never act blind.

export type ClarificationCandidate = {
  targetId: string;
  label: string;
  confidence: number;
  surface?: SurfaceSnapshot;
};

export type ClarificationPolicy = {
  // Below this calibrated confidence even the best candidate isn't trustworthy.
  minConfidence: number;
  // If the top two candidates are within this margin they're indistinguishable.
  ambiguityMargin: number;
};

export type ClarificationDecision =
  | { kind: "act"; targetId: string }
  | { kind: "clarify"; request: ClarificationRequest };

// Starting thresholds — tune on real recorded data (ties to the #29 golden
// refresh + #100 temperature fit). fuse-intent already defaults a 0.5 floor;
// clarification sits slightly above it so a weak-but-passing bind still confirms.
export const DEFAULT_CLARIFICATION_POLICY: ClarificationPolicy = {
  minConfidence: 0.6,
  ambiguityMargin: 0.1,
};

const QUESTIONS: Record<ClarificationReason, string> = {
  low_confidence: "Pointing confidence was low — please confirm the target.",
  ambiguous: "Which target did you mean?",
  no_target: "No target found where you pointed — re-point and try again.",
};

function toOption(c: ClarificationCandidate): ClarificationOption {
  return {
    targetId: c.targetId,
    label: c.label,
    confidence: c.confidence,
    ...(c.surface ? { surface: c.surface } : {}),
  };
}

function clarify(
  reason: ClarificationReason,
  options: ClarificationOption[],
): ClarificationDecision {
  return { kind: "clarify", request: { reason, question: QUESTIONS[reason], options } };
}

export function decideClarification(
  candidates: ClarificationCandidate[],
  policy: ClarificationPolicy = DEFAULT_CLARIFICATION_POLICY,
): ClarificationDecision {
  const ranked = [...candidates].sort((a, b) => b.confidence - a.confidence);
  const options = ranked.map(toOption);
  const top = ranked[0];

  // Nothing under the ray → ask the user to re-point (no options to offer).
  if (!top) return clarify("no_target", []);

  // Best candidate isn't trustworthy — confirm before acting (takes precedence:
  // an ambiguous-but-weak set is still fundamentally too weak to act on).
  if (top.confidence < policy.minConfidence) return clarify("low_confidence", options);

  // Two plausible targets too close to choose between — let the user pick.
  const second = ranked[1];
  if (second && top.confidence - second.confidence < policy.ambiguityMargin) {
    return clarify("ambiguous", options);
  }

  return { kind: "act", targetId: top.targetId };
}
