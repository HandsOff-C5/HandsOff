import { describe, expect, it } from "vitest";

import { pointingEvidenceSchema } from "./intent";
import {
  safeParseAttentionRegionCandidate,
  safeParseHeadPointingAppEvent,
  safeParseHeadPointingEvent,
  safeParseHeadPointingEvidence,
} from "./head-pointing";
import type { SurfaceSnapshot } from "./surface";

const surface: SurfaceSnapshot = {
  id: "surface-1",
  title: "Codex",
  app: "Codex",
  pid: 42,
  windowId: 7,
  availability: "available",
  accessStatus: "accessible",
};

describe("headPointingEventSchema", () => {
  it.each([
    { kind: "start", ts: 1 },
    { kind: "stop", ts: 2 },
    { kind: "error", message: "camera unavailable", ts: 3 },
  ])("parses the existing $kind wire event", (event) => {
    expect(safeParseHeadPointingEvent(event).success).toBe(true);
  });

  it("parses the sidecar point wire event", () => {
    const parsed = safeParseHeadPointingEvent({
      kind: "point",
      x: -1191,
      y: -1080,
      yaw: 0.12,
      pitch: -0.05,
      confidence: 0.86,
      ts: 1_803_000_000_001,
    });

    expect(parsed.success).toBe(true);
    if (parsed.success) expect(parsed.data.kind).toBe("point");
  });

  it("accepts null pose values from Apple Vision", () => {
    const parsed = safeParseHeadPointingEvent({
      kind: "point",
      x: 10,
      y: 20,
      yaw: null,
      pitch: null,
      confidence: 0.7,
      ts: 1,
    });

    expect(parsed.success).toBe(true);
  });

  it("rejects invalid confidence and non-finite coordinates", () => {
    expect(
      safeParseHeadPointingEvent({
        kind: "point",
        x: Number.POSITIVE_INFINITY,
        y: 20,
        yaw: null,
        pitch: null,
        confidence: 0.7,
        ts: 1,
      }).success,
    ).toBe(false);

    expect(
      safeParseHeadPointingEvent({
        kind: "point",
        x: 10,
        y: 20,
        yaw: null,
        pitch: null,
        confidence: 1.2,
        ts: 1,
      }).success,
    ).toBe(false);
  });

  it("parses the app candidates wire event", () => {
    const parsed = safeParseHeadPointingAppEvent({
      kind: "candidates",
      point: { x: 10, y: 20 },
      candidates: [{ surface, score: 0.94, distance: 12 }],
      ts: 4,
    });

    expect(parsed.success).toBe(true);
    if (parsed.success) expect(parsed.data.kind).toBe("candidates");
  });
});

describe("attentionRegionCandidateSchema", () => {
  it("parses a ranked attention-region candidate", () => {
    const parsed = safeParseAttentionRegionCandidate({
      surface,
      score: 0.94,
      distance: 12,
    });

    expect(parsed.success).toBe(true);
  });

  it("maps cleanly into head-source pointing evidence", () => {
    const candidate = { surface, score: 0.94, distance: 12 };
    const parsedCandidate = safeParseAttentionRegionCandidate(candidate);
    expect(parsedCandidate.success).toBe(true);

    const evidence = {
      source: "head",
      confidence: candidate.score,
      strategy: "head-neighborhood",
      surface: candidate.surface,
      cursor: { x: 10, y: 20 },
    };

    expect(safeParseHeadPointingEvidence(evidence).success).toBe(true);
    expect(pointingEvidenceSchema.safeParse(evidence).success).toBe(true);
  });
});
