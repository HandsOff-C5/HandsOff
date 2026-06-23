import { describe, expect, it } from "vitest";

import type { PointingEvidence } from "@handsoff/contracts";

import { alignPointingEvidence, type TimedPointingEvidence } from "./temporal-alignment";

function ev(source: PointingEvidence["source"], confidence = 0.9): PointingEvidence {
  return { source, confidence, strategy: `${source}-strategy` };
}
function timed(
  at: number,
  source: PointingEvidence["source"],
  confidence = 0.9,
): TimedPointingEvidence {
  return { at, evidence: ev(source, confidence) };
}

describe("alignPointingEvidence", () => {
  it("returns evidence whose timestamp falls inside the utterance window", () => {
    const buffer = [timed(900, "gesture"), timed(1000, "head"), timed(5000, "gesture")];
    const aligned = alignPointingEvidence(
      buffer,
      { startMs: 850, endMs: 1100 },
      { toleranceMs: 0 },
    );
    expect(aligned.map((e) => e.source).sort()).toEqual(["gesture", "head"]);
  });

  it("expands the window by the tolerance on each side", () => {
    const buffer = [timed(300, "gesture")]; // 200ms before the window start
    expect(
      alignPointingEvidence(buffer, { startMs: 500, endMs: 800 }, { toleranceMs: 250 }),
    ).toHaveLength(1);
    expect(
      alignPointingEvidence(buffer, { startMs: 500, endMs: 800 }, { toleranceMs: 100 }),
    ).toHaveLength(0);
  });

  it("keeps only the latest evidence per source within the window", () => {
    const buffer = [timed(160, "gesture", 0.7), timed(200, "gesture", 0.95)];
    const aligned = alignPointingEvidence(buffer, { startMs: 150, endMs: 250 }, { toleranceMs: 0 });
    expect(aligned).toHaveLength(1);
    expect(aligned[0]?.confidence).toBe(0.95); // the t=200 sample
  });

  it("orders the selected evidence by timestamp ascending", () => {
    const buffer = [timed(240, "head"), timed(160, "gesture")];
    const aligned = alignPointingEvidence(buffer, { startMs: 150, endMs: 250 }, { toleranceMs: 0 });
    expect(aligned.map((e) => e.source)).toEqual(["gesture", "head"]);
  });

  it("returns empty when nothing lands in the window, even if stale samples exist", () => {
    // Stale pointing must NOT be treated as aligned (AD5: clarify, don't guess).
    const buffer = [timed(100, "gesture"), timed(5000, "head")];
    const aligned = alignPointingEvidence(
      buffer,
      { startMs: 900, endMs: 1000 },
      { toleranceMs: 50 },
    );
    expect(aligned).toEqual([]);
  });

  it("returns an empty array for an empty buffer", () => {
    expect(alignPointingEvidence([], { startMs: 0, endMs: 100 })).toEqual([]);
  });
});
