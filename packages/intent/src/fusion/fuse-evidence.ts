import type { PointingEvidence, SurfaceSnapshot } from "@handsoff/contracts";

// True multimodal fusion of pointing evidence (vs. the winner-take-all selection
// in fuse-intent). Every channel that resolved a surface casts a vote for that
// target; votes on the SAME target combine by noisy-OR so agreement compounds
// confidence above any single channel, and votes on DIFFERENT targets compete so
// the spread is an explicit disagreement signal. The `drag` names the channel
// most responsible for the noise — the "what do I adjust to reduce it" lever.

export type FusionVote = {
  source: PointingEvidence["source"];
  confidence: number;
  strategy: string;
};

export type FusedTarget = {
  targetId: string;
  label: string;
  surface: SurfaceSnapshot;
  fusedConfidence: number;
  votes: FusionVote[];
};

export type FusionDecisionKind =
  | "act"
  | "clarify_low_confidence"
  | "clarify_ambiguous"
  | "no_target";

export type FusionDrag = {
  source: PointingEvidence["source"] | "none";
  reason: "disagreement" | "below_threshold" | "ambiguous" | "no_target";
  detail: string;
};

export type EvidenceFusion = {
  targets: FusedTarget[];
  winner?: FusedTarget;
  runnerUp?: FusedTarget;
  margin?: number;
  minConfidence: number;
  ambiguityMargin: number;
  decision: FusionDecisionKind;
  fusedConfidence: number;
  drag?: FusionDrag;
};

export type FuseEvidenceOptions = {
  minConfidence?: number;
  ambiguityMargin?: number;
};

const DEFAULT_MIN_CONFIDENCE = 0.5;
const DEFAULT_AMBIGUITY_MARGIN = 0.1;

// Combine independent votes for one target. Noisy-OR: the chance at least one is
// right, treating channels as independent evidence — so two agreeing votes land
// above either alone (0.9, 0.6 -> 0.96) and never exceed 1.
function noisyOr(confidences: readonly number[]): number {
  return 1 - confidences.reduce((product, c) => product * (1 - c), 1);
}

// The channel most responsible for a target's score (its strongest vote).
function dominantSource(target: FusedTarget): PointingEvidence["source"] {
  return [...target.votes].sort((a, b) => b.confidence - a.confidence)[0]?.source ?? "fusion";
}

export function fuseEvidence(
  evidence: readonly PointingEvidence[],
  options: FuseEvidenceOptions = {},
): EvidenceFusion {
  const minConfidence = options.minConfidence ?? DEFAULT_MIN_CONFIDENCE;
  const ambiguityMargin = options.ambiguityMargin ?? DEFAULT_AMBIGUITY_MARGIN;

  // Group every surface-bearing vote by its target, then fuse per target.
  const byTarget = new Map<string, FusedTarget>();
  for (const e of evidence) {
    if (!e.surface) continue;
    const existing = byTarget.get(e.surface.id);
    const voteEntry: FusionVote = {
      source: e.source,
      confidence: e.confidence,
      strategy: e.strategy,
    };
    if (existing) {
      existing.votes.push(voteEntry);
    } else {
      byTarget.set(e.surface.id, {
        targetId: e.surface.id,
        label: `${e.surface.app} — ${e.surface.title}`,
        surface: e.surface,
        fusedConfidence: 0,
        votes: [voteEntry],
      });
    }
  }

  const targets = [...byTarget.values()];
  for (const target of targets) {
    target.fusedConfidence = noisyOr(target.votes.map((v) => v.confidence));
  }
  targets.sort((a, b) => b.fusedConfidence - a.fusedConfidence);

  const base = { targets, minConfidence, ambiguityMargin };

  const winner = targets[0];
  if (!winner) {
    return {
      ...base,
      decision: "no_target",
      fusedConfidence: 0,
      drag: {
        source: "none",
        reason: "no_target",
        detail: "No target was found under the pointing.",
      },
    };
  }

  const runnerUp = targets[1];
  const margin = winner.fusedConfidence - (runnerUp?.fusedConfidence ?? 0);
  const withTop = { ...base, winner, fusedConfidence: winner.fusedConfidence, margin };

  if (winner.fusedConfidence < minConfidence) {
    return {
      ...withTop,
      decision: "clarify_low_confidence",
      drag: {
        source: dominantSource(winner),
        reason: "below_threshold",
        detail: `${winner.label} fused to ${winner.fusedConfidence.toFixed(2)}, below the ${minConfidence} floor.`,
      },
    };
  }

  if (runnerUp && margin < ambiguityMargin) {
    return {
      ...withTop,
      runnerUp,
      decision: "clarify_ambiguous",
      drag: {
        source: dominantSource(runnerUp),
        reason: "ambiguous",
        detail: `${winner.label} (${winner.fusedConfidence.toFixed(2)}) and ${runnerUp.label} (${runnerUp.fusedConfidence.toFixed(2)}) are within ${ambiguityMargin}.`,
      },
    };
  }

  // Acting — but if a different target drew votes, name the disagreeing channel
  // so the noise is visible even though we proceeded.
  if (runnerUp) {
    return {
      ...withTop,
      runnerUp,
      decision: "act",
      drag: {
        source: dominantSource(runnerUp),
        reason: "disagreement",
        detail: `Acting on ${winner.label} (${winner.fusedConfidence.toFixed(2)}); ${dominantSource(runnerUp)} pulled toward ${runnerUp.label} (${runnerUp.fusedConfidence.toFixed(2)}).`,
      },
    };
  }

  return { ...withTop, decision: "act" };
}
