import type {
  FinalTranscript,
  PointingCandidate,
  PointingEvidence,
  SurfaceSnapshot,
  TranscriptWord,
} from "@handsoff/contracts";
import type { AttentionWindow } from "@handsoff/intent";
import { describe, expect, it, vi } from "vitest";

import { buildPointingEvidence, type PointingContext } from "./buildPointingEvidence";
import type { CaptureTrace } from "../capture-trace";
import type { HeadPointingSnapshot } from "../head-pointing/useHeadPointing";

function surface(overrides: Partial<SurfaceSnapshot> = {}): SurfaceSnapshot {
  return {
    id: "surface-1",
    title: "Codex",
    app: "Codex",
    availability: "available",
    accessStatus: "accessible",
    ...overrides,
  };
}

const transcript: FinalTranscript = {
  kind: "final",
  text: "click that",
  confidence: 0.95,
  latencyMs: 100,
  receivedAt: 1,
};

function emptyContext(overrides: Partial<PointingContext> = {}): PointingContext {
  return {
    gestureEvidence: null,
    gestureCursor: null,
    captureTrace: null,
    pointableWindows: [],
    ...overrides,
  };
}

const fallbackSurface = surface({ id: "active-window", title: "Active", app: "Active" });
const resolveFallback = () => Promise.resolve(fallbackSurface);

describe("buildPointingEvidence — combinative fusion", () => {
  it("combines a locked gesture referent with face-tracker + head-neighborhood evidence", async () => {
    const gesture: PointingEvidence = {
      source: "gesture",
      confidence: 0.9,
      strategy: "wrist-ray-calibrated:good",
      surface: surface({ id: "gesture-target", app: "Demo" }),
    };
    const headPointing: HeadPointingSnapshot = {
      point: { x: 10, y: 20 },
      candidates: [{ surface: surface({ id: "head-target" }), score: 0.8, distance: 0 }],
    };

    const { pointingEvidence, surfaceCandidates } = await buildPointingEvidence(
      transcript,
      emptyContext({ gestureEvidence: gesture }),
      headPointing,
      resolveFallback,
    );

    expect(pointingEvidence).toEqual(
      expect.arrayContaining([
        gesture,
        expect.objectContaining({ source: "head", strategy: "face-tracker-position" }),
        expect.objectContaining({ source: "head", strategy: "head-neighborhood" }),
      ]),
    );
    // Deduplicated candidates from every evidence carrying a surface.
    expect(surfaceCandidates.map((s) => s.id)).toEqual(
      expect.arrayContaining(["gesture-target", "head-target"]),
    );
  });

  it("adds a wrist-ray cursor entry when a gesture cursor but no locked referent is present", async () => {
    const headPointing: HeadPointingSnapshot = { point: { x: 1, y: 2 }, candidates: [] };
    const { pointingEvidence } = await buildPointingEvidence(
      transcript,
      emptyContext({ gestureCursor: { x: 0.6, y: 0.4 } }),
      headPointing,
      resolveFallback,
    );

    expect(pointingEvidence).toEqual(
      expect.arrayContaining([
        expect.objectContaining({
          source: "gesture",
          strategy: "wrist-ray-position",
          cursor: { x: 0.6, y: 0.4 },
        }),
      ]),
    );
  });

  it("emits a head-neighborhood-empty entry when head is present with no candidates", async () => {
    const headPointing: HeadPointingSnapshot = { point: { x: 10, y: 20 }, candidates: [] };
    const { pointingEvidence, surfaceCandidates } = await buildPointingEvidence(
      transcript,
      emptyContext(),
      headPointing,
      resolveFallback,
    );

    expect(pointingEvidence).toEqual([
      {
        source: "head",
        confidence: 0.5,
        strategy: "face-tracker-position",
        cursor: { x: 10, y: 20 },
      },
      {
        source: "head",
        confidence: 0,
        strategy: "head-neighborhood-empty",
        cursor: { x: 10, y: 20 },
      },
    ]);
    expect(surfaceCandidates).toEqual([]);
  });
});

describe("buildPointingEvidence — active-window fallback", () => {
  it("falls back to the active window only when no gesture/head/bound evidence exists", async () => {
    const resolve = vi.fn(resolveFallback);
    const { pointingEvidence, surfaceCandidates } = await buildPointingEvidence(
      transcript,
      emptyContext(),
      undefined,
      resolve,
    );

    expect(resolve).toHaveBeenCalledOnce();
    expect(pointingEvidence).toEqual([
      {
        source: "cursor",
        confidence: 1,
        strategy: "active-window-current-cursor",
        surface: fallbackSurface,
      },
    ]);
    expect(surfaceCandidates).toEqual([fallbackSurface]);
  });

  it("does NOT resolve the fallback when other evidence is present", async () => {
    const resolve = vi.fn(resolveFallback);
    await buildPointingEvidence(
      transcript,
      emptyContext(),
      { point: { x: 1, y: 2 }, candidates: [] },
      resolve,
    );
    expect(resolve).not.toHaveBeenCalled();
  });
});

describe("buildPointingEvidence — U7 temporal multi-target binding", () => {
  const notesSurface: SurfaceSnapshot = {
    id: "win-notes",
    title: "Notes",
    app: "Notes",
    availability: "available",
    accessStatus: "accessible",
  };
  const slackSurface: SurfaceSnapshot = {
    id: "win-slack",
    title: "Slack",
    app: "Slack",
    availability: "available",
    accessStatus: "accessible",
  };
  const pointableWindows: readonly AttentionWindow[] = [
    { surface: notesSurface, bounds: { x: 0, y: 0, width: 400, height: 400 } },
    { surface: slackSurface, bounds: { x: 1000, y: 0, width: 400, height: 400 } },
  ];

  function word(text: string, startMs: number, endMs: number): TranscriptWord {
    return { text, startMs, endMs, confidence: 0.9 };
  }

  function handAt(tsMs: number, targetId: string): CaptureTrace["handTrace"][number] {
    const candidate: PointingCandidate = { targetId, confidence: 0.85, calibrationQuality: "good" };
    return { x: targetId === "win-notes" ? 200 : 1200, y: 200, candidate, phase: "locked", tsMs };
  }

  const twoTargetWords: readonly TranscriptWord[] = [
    word("type", 100, 300),
    word("Laura", 300, 600),
    word("in", 600, 800),
    word("this", 1000, 1300),
    word("and", 8000, 8200),
    word("hello", 8200, 8500),
    word("in", 8900, 9000),
    word("that", 9000, 9300),
  ];
  const twoTargetTrace: CaptureTrace = {
    headTrace: [],
    handTrace: [handAt(1100, "win-notes"), handAt(9100, "win-slack")],
    words: twoTargetWords,
  };
  const twoTargetTranscript: FinalTranscript = {
    kind: "final",
    text: "type Laura in this and hello in that",
    confidence: 0.95,
    latencyMs: 100,
    receivedAt: 1,
    words: twoTargetWords,
  };

  it("binds two deictic words to two distinct surfaces, leading the evidence list", async () => {
    const { pointingEvidence, surfaceCandidates } = await buildPointingEvidence(
      twoTargetTranscript,
      emptyContext({ captureTrace: twoTargetTrace, pointableWindows }),
      { point: null, candidates: [] },
      resolveFallback,
    );

    const fusion = pointingEvidence.filter((e) => e.source === "fusion");
    expect(fusion).toEqual(
      expect.arrayContaining([
        expect.objectContaining({
          source: "fusion",
          strategy: "temporal-bind:this@1100",
          surface: expect.objectContaining({ id: "win-notes" }),
        }),
        expect.objectContaining({
          source: "fusion",
          strategy: "temporal-bind:that@9100",
          surface: expect.objectContaining({ id: "win-slack" }),
        }),
      ]),
    );
    // Bound (fusion) evidence leads the array — its surfaces win the dedup.
    expect(pointingEvidence[0]!.source).toBe("fusion");
    const candidateIds = surfaceCandidates.map((s) => s.id);
    expect(candidateIds).toContain("win-notes");
    expect(candidateIds).toContain("win-slack");
  });

  it("contributes nothing (snapshot fallback preserved) when there is no pointable layout", async () => {
    const { pointingEvidence } = await buildPointingEvidence(
      twoTargetTranscript,
      emptyContext({ captureTrace: twoTargetTrace, pointableWindows: [] }),
      undefined,
      resolveFallback,
    );
    expect(pointingEvidence.some((e) => e.source === "fusion")).toBe(false);
    // No other evidence → the active-window fallback is the sole signal.
    expect(pointingEvidence).toEqual([
      expect.objectContaining({ strategy: "active-window-current-cursor" }),
    ]);
  });
});
