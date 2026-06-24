import type { AttentionRegionCandidate, SurfaceSnapshot } from "@handsoff/contracts";

import type { HeadFaceFrame } from "./head-face";

export type HeadFaceAttentionRegionName = "left" | "center" | "right";

export interface HeadFaceAttentionRegion {
  region: HeadFaceAttentionRegionName;
  surface: SurfaceSnapshot;
}

export interface HeadFaceAttentionCandidate extends AttentionRegionCandidate {
  timestampMs: number;
  provenance: "head-face";
  region: HeadFaceAttentionRegionName;
}

export interface HeadFaceAttentionOptions {
  minConfidence?: number;
  sideThreshold?: number;
}

export function headFaceAttentionCandidates(
  frame: HeadFaceFrame,
  regions: readonly HeadFaceAttentionRegion[],
  options: HeadFaceAttentionOptions = {},
): HeadFaceAttentionCandidate[] {
  const minConfidence = options.minConfidence ?? 0.5;
  const sideThreshold = options.sideThreshold ?? 0.35;

  return frame.cues
    .flatMap((cue) => {
      if (cue.confidence < minConfidence || cue.noseOffset === null) return [];

      const region = regionFromOffset(cue.noseOffset.x, sideThreshold);
      const match = regions.find((candidate) => candidate.region === region);
      if (!match) return [];

      return [
        {
          surface: match.surface,
          score: round3(cue.confidence),
          distance: round3(Math.abs(cue.noseOffset.x)),
          timestampMs: frame.timestampMs,
          provenance: "head-face" as const,
          region,
        },
      ];
    })
    .sort(
      (a, b) =>
        b.score - a.score || a.distance - b.distance || a.surface.id.localeCompare(b.surface.id),
    );
}

function regionFromOffset(x: number, sideThreshold: number): HeadFaceAttentionRegionName {
  if (x <= -sideThreshold) return "left";
  if (x >= sideThreshold) return "right";
  return "center";
}

function round3(value: number): number {
  return Math.round(value * 1000) / 1000;
}
