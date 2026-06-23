import { describe, expect, it } from "vitest";

import { rankAttentionCandidates } from "./candidates";
import goldens from "../fixtures/head-pointing/candidate-goldens.json";
import type { AttentionRegionCandidate, HeadPoint } from "@handsoff/contracts";

type Golden = {
  readonly name: string;
  readonly point: HeadPoint;
  readonly radius: number;
  readonly windows: Parameters<typeof rankAttentionCandidates>[1];
  readonly expected: readonly AttentionRegionCandidate[];
};

type ReplayGolden = {
  readonly name: string;
  readonly points: readonly HeadPoint[];
  readonly radius: number;
  readonly windows: Parameters<typeof rankAttentionCandidates>[1];
  readonly expectedTopSurfaceIds: readonly string[];
};

type CandidateGolden = Golden | ReplayGolden;

describe("rankAttentionCandidates", () => {
  it.each(goldens as readonly CandidateGolden[])("$name", (golden) => {
    if ("points" in golden) {
      const topSurfaceIds = golden.points.map((point) => {
        return rankAttentionCandidates(point, golden.windows, { radius: golden.radius })[0]?.surface
          .id;
      });

      expect(topSurfaceIds).toEqual(golden.expectedTopSurfaceIds);
      return;
    }

    expect(
      rankAttentionCandidates(golden.point, golden.windows, { radius: golden.radius }),
    ).toEqual(golden.expected);
  });
});
