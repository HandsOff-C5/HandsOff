import type {
  AttentionRegionCandidate,
  HeadPoint,
  PointingEvidence,
  SurfaceSnapshot,
} from "@handsoff/contracts";

export type PerceptionTargetProvenance = Exclude<PointingEvidence["source"], "fusion">;

export type PerceptionTargetDisagreementReason =
  | "source_disagreement"
  | "low_confidence"
  | "no_target";

export type PerceptionTargetCandidate = {
  confidence: number;
  provenance: readonly PerceptionTargetProvenance[];
  disagreementReason?: PerceptionTargetDisagreementReason;
  surface?: SurfaceSnapshot;
  evidence: PointingEvidence;
};

export type PerceptionTargetFusion = {
  target: PerceptionTargetCandidate;
  pointingEvidence: readonly PointingEvidence[];
  surfaceCandidates: readonly SurfaceSnapshot[];
};

export type FusePerceptionTargetInput = {
  gesture?: PointingEvidence | null;
  headCandidates?: readonly AttentionRegionCandidate[];
  headPoint?: HeadPoint | null;
  fallback?: PointingEvidence | null;
};

const LOW_CONFIDENCE_THRESHOLD = 0.5;

export function fusePerceptionTarget(input: FusePerceptionTargetInput): PerceptionTargetFusion {
  const headCandidates = rankHeadCandidates(input.headCandidates ?? []);
  const topHead = headCandidates[0];

  if (hasSurface(input.gesture)) {
    return topHead
      ? fuseGestureWithHead(input.gesture, topHead, input.headPoint ?? null, headCandidates)
      : fromEvidence(input.gesture, ["gesture"], undefined, [input.gesture.surface]);
  }

  if (topHead) {
    const evidence = headEvidence(topHead, input.headPoint ?? null);
    return fromEvidence(
      evidence,
      ["head"],
      undefined,
      headCandidates.map((c) => c.surface),
    );
  }

  if (input.headPoint) {
    const evidence: PointingEvidence = {
      source: "head",
      confidence: 0,
      strategy: "head-neighborhood-empty",
      cursor: input.headPoint,
    };
    return fromEvidence(evidence, ["head"], "no_target", []);
  }

  if (input.fallback) {
    return fromEvidence(
      input.fallback,
      provenanceFromEvidence(input.fallback),
      undefined,
      input.fallback.surface ? [input.fallback.surface] : [],
    );
  }

  const evidence: PointingEvidence = {
    source: "cursor",
    confidence: 0,
    strategy: "no-perception-target",
  };
  return fromEvidence(evidence, ["cursor"], "no_target", []);
}

function fuseGestureWithHead(
  gesture: PointingEvidence & { surface: SurfaceSnapshot },
  head: AttentionRegionCandidate,
  headPoint: HeadPoint | null,
  headCandidates: readonly AttentionRegionCandidate[],
): PerceptionTargetFusion {
  if (sameSurface(gesture.surface, head.surface)) {
    const confidence = round3(Math.max(gesture.confidence, head.score));
    const evidence: PointingEvidence = {
      source: "fusion",
      confidence,
      strategy: `${gesture.strategy}+head-face-agree`,
      surface: gesture.surface,
    };
    return fromEvidence(evidence, ["gesture", "head"], undefined, [gesture.surface]);
  }

  const confidence = round3(gesture.confidence * 0.5);
  const evidence: PointingEvidence = {
    source: "fusion",
    confidence,
    strategy: `${gesture.strategy}+head-face-disagree`,
    surface: gesture.surface,
    ...(headPoint ? { cursor: headPoint } : {}),
  };
  return fromEvidence(evidence, ["gesture", "head"], "source_disagreement", [
    gesture.surface,
    ...headCandidates.map((c) => c.surface),
  ]);
}

function headEvidence(
  candidate: AttentionRegionCandidate,
  headPoint: HeadPoint | null,
): PointingEvidence {
  return {
    source: "head",
    confidence: round3(candidate.score),
    strategy: "head-neighborhood",
    surface: candidate.surface,
    ...(headPoint ? { cursor: headPoint } : {}),
  };
}

function fromEvidence(
  evidence: PointingEvidence,
  provenance: readonly PerceptionTargetProvenance[],
  reason: PerceptionTargetDisagreementReason | undefined,
  surfaces: readonly SurfaceSnapshot[],
): PerceptionTargetFusion {
  const disagreementReason =
    reason ?? (evidence.confidence < LOW_CONFIDENCE_THRESHOLD ? "low_confidence" : undefined);
  const target: PerceptionTargetCandidate = {
    confidence: round3(evidence.confidence),
    provenance,
    ...(disagreementReason ? { disagreementReason } : {}),
    ...(evidence.surface ? { surface: evidence.surface } : {}),
    evidence,
  };
  return {
    target,
    pointingEvidence: [evidence],
    surfaceCandidates: uniqueSurfaces(surfaces),
  };
}

function rankHeadCandidates(
  candidates: readonly AttentionRegionCandidate[],
): AttentionRegionCandidate[] {
  return [...candidates].sort((a, b) => {
    const byScore = b.score - a.score;
    if (byScore !== 0) return byScore;
    const byDistance = a.distance - b.distance;
    if (byDistance !== 0) return byDistance;
    return a.surface.id.localeCompare(b.surface.id);
  });
}

function uniqueSurfaces(surfaces: readonly SurfaceSnapshot[]): SurfaceSnapshot[] {
  const seen = new Set<string>();
  return surfaces.filter((surface) => {
    if (seen.has(surface.id)) return false;
    seen.add(surface.id);
    return true;
  });
}

function sameSurface(a: SurfaceSnapshot | undefined, b: SurfaceSnapshot): a is SurfaceSnapshot {
  return a?.id === b.id;
}

function hasSurface(
  evidence: PointingEvidence | null | undefined,
): evidence is PointingEvidence & { surface: SurfaceSnapshot } {
  return evidence?.surface !== undefined;
}

function provenanceFromEvidence(evidence: PointingEvidence): readonly PerceptionTargetProvenance[] {
  return evidence.source === "fusion" ? ["gesture", "head"] : [evidence.source];
}

function round3(value: number): number {
  return Math.round(value * 1000) / 1000;
}
