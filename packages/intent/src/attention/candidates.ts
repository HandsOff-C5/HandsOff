import type { AttentionRegionCandidate, HeadPoint, SurfaceSnapshot } from "@handsoff/contracts";

export const DEFAULT_HEAD_NEIGHBORHOOD_RADIUS = 240;

export interface AttentionWindowBounds {
  readonly x: number;
  readonly y: number;
  readonly width: number;
  readonly height: number;
}

export interface AttentionWindow {
  readonly surface: SurfaceSnapshot;
  readonly bounds: AttentionWindowBounds;
  readonly zIndex?: number;
}

export interface RankAttentionCandidateOptions {
  readonly radius?: number;
}

export function rankAttentionCandidates(
  point: HeadPoint,
  windows: readonly AttentionWindow[],
  options: RankAttentionCandidateOptions = {},
): AttentionRegionCandidate[] {
  const radius = options.radius ?? DEFAULT_HEAD_NEIGHBORHOOD_RADIUS;
  if (radius <= 0) return [];

  return windows
    .filter((window) => isRankable(window))
    .map((window) => {
      const distance = round3(distanceToBounds(point, window.bounds));
      return {
        surface: window.surface,
        score: round3(1 - distance / radius),
        distance,
        zIndex: window.zIndex ?? 0,
      };
    })
    .filter((candidate) => candidate.distance <= radius)
    .sort(
      (a, b) =>
        b.score - a.score ||
        a.distance - b.distance ||
        b.zIndex - a.zIndex ||
        a.surface.id.localeCompare(b.surface.id),
    )
    .map(({ surface, score, distance }) => ({ surface, score, distance }));
}

function isRankable(window: AttentionWindow): boolean {
  return (
    window.surface.availability === "available" &&
    window.surface.accessStatus === "accessible" &&
    !window.surface.app.toLowerCase().includes("cua driver") &&
    window.bounds.width > 0 &&
    window.bounds.height > 0
  );
}

function distanceToBounds(point: HeadPoint, bounds: AttentionWindowBounds): number {
  const nearestX = clamp(point.x, bounds.x, bounds.x + bounds.width);
  const nearestY = clamp(point.y, bounds.y, bounds.y + bounds.height);
  return Math.hypot(point.x - nearestX, point.y - nearestY);
}

function clamp(value: number, min: number, max: number): number {
  return Math.min(Math.max(value, min), max);
}

function round3(value: number): number {
  return Math.round(value * 1000) / 1000;
}
