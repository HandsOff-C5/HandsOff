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

describe("rankAttentionCandidates", () => {
  it.each(goldens as readonly Golden[])("$name", (golden) => {
    expect(
      rankAttentionCandidates(golden.point, golden.windows, { radius: golden.radius }),
    ).toEqual(golden.expected);
  });
});
