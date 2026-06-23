import type { PointingEvidence, SurfaceSnapshot } from "@handsoff/contracts";
import { describe, expect, it } from "vitest";

import { fuseEvidence } from "./fuse-evidence";

function surface(id: string, app: string, title: string): SurfaceSnapshot {
  return { id, app, title, availability: "available", accessStatus: "accessible" };
}

function vote(
  source: PointingEvidence["source"],
  confidence: number,
  target: SurfaceSnapshot,
): PointingEvidence {
  return { source, confidence, strategy: `${source}-test`, surface: target };
}

const cursor = surface("win:cursor", "Cursor", "editor");
const slack = surface("win:slack", "Slack", "general");

describe("fuseEvidence (noisy-OR multimodal fusion)", () => {
  it("a single channel on one target fuses to its own confidence and acts", () => {
    const result = fuseEvidence([vote("gesture", 0.9, cursor)]);
    expect(result.winner?.targetId).toBe("win:cursor");
    expect(result.fusedConfidence).toBeCloseTo(0.9);
    expect(result.decision).toBe("act");
    expect(result.drag).toBeUndefined();
  });

  it("two channels AGREEING on one target compound above either alone", () => {
    const result = fuseEvidence([vote("gesture", 0.9, cursor), vote("gaze", 0.6, cursor)]);
    // noisy-OR: 1 - (1-0.9)(1-0.6) = 0.96
    expect(result.fusedConfidence).toBeCloseTo(0.96);
    expect(result.winner?.votes).toHaveLength(2);
    expect(result.decision).toBe("act");
    expect(result.drag).toBeUndefined();
  });

  it("channels DISAGREEING still act on the stronger target but surface the drag", () => {
    const result = fuseEvidence([vote("gesture", 0.9, cursor), vote("gaze", 0.5, slack)]);
    expect(result.winner?.targetId).toBe("win:cursor");
    expect(result.runnerUp?.targetId).toBe("win:slack");
    expect(result.margin).toBeCloseTo(0.4);
    expect(result.decision).toBe("act");
    expect(result.drag).toMatchObject({ source: "gaze", reason: "disagreement" });
    expect(result.drag?.detail).toContain("Slack");
  });

  it("two targets within the ambiguity margin clarify (drag = ambiguous)", () => {
    const result = fuseEvidence([vote("gesture", 0.9, cursor), vote("gaze", 0.85, slack)]);
    expect(result.margin).toBeCloseTo(0.05);
    expect(result.decision).toBe("clarify_ambiguous");
    expect(result.drag?.reason).toBe("ambiguous");
  });

  it("a winner below the confidence floor clarifies (drag = below_threshold)", () => {
    const result = fuseEvidence([vote("gesture", 0.4, cursor)]);
    expect(result.decision).toBe("clarify_low_confidence");
    expect(result.drag).toMatchObject({ source: "gesture", reason: "below_threshold" });
  });

  it("no surface-bearing evidence yields no_target", () => {
    const result = fuseEvidence([{ source: "head", confidence: 0.5, strategy: "head-empty" }]);
    expect(result.targets).toHaveLength(0);
    expect(result.decision).toBe("no_target");
    expect(result.drag?.reason).toBe("no_target");
  });

  it("targets are ranked by fused confidence, highest first", () => {
    const result = fuseEvidence([vote("gaze", 0.5, slack), vote("gesture", 0.9, cursor)]);
    expect(result.targets.map((t) => t.targetId)).toEqual(["win:cursor", "win:slack"]);
  });
});
