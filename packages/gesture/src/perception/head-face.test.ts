import { readFileSync, statSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

import {
  safeParseAttentionRegionCandidate,
  type AttentionRegionCandidate,
} from "@handsoff/contracts";
import { describe, expect, it } from "vitest";

import { parseHeadFaceFrame, type HeadFaceFrame, type RawHeadFaceFrame } from "./head-face";

const fixturesDir = join(dirname(fileURLToPath(import.meta.url)), "../../fixtures");

interface Recorded {
  timestampMs: number;
  raw: RawHeadFaceFrame;
}

interface Golden extends HeadFaceFrame {
  candidates: AttentionRegionCandidate[];
}

const load = <T>(file: string): T => JSON.parse(readFileSync(join(fixturesDir, file), "utf8")) as T;

const FIXTURES = [
  "head-face-present",
  "head-face-none",
  "head-face-off-axis",
  "head-face-low-confidence",
] as const;

function expectClose(actual: unknown, expected: unknown) {
  if (typeof expected === "number") {
    expect(actual).toBeCloseTo(expected, 6);
    return;
  }
  if (Array.isArray(expected)) {
    expect(Array.isArray(actual)).toBe(true);
    expect(actual).toHaveLength(expected.length);
    expected.forEach((value, index) => expectClose((actual as unknown[])[index], value));
    return;
  }
  if (expected && typeof expected === "object") {
    expect(actual && typeof actual === "object").toBe(true);
    expect(Object.keys(actual as Record<string, unknown>).sort()).toEqual(
      Object.keys(expected).sort(),
    );
    for (const key of Object.keys(expected)) {
      expectClose(
        (actual as Record<string, unknown>)[key],
        (expected as Record<string, unknown>)[key],
      );
    }
    return;
  }
  expect(actual).toEqual(expected);
}

describe("head/face recorded-frame fixtures", () => {
  it.each(FIXTURES)("%s: parser reconstructs cue golden with float tolerance", (name) => {
    const recording = load<Recorded[]>(`${name}.frames.json`);
    const golden = load<Golden[]>(`${name}.golden.json`);

    expect(recording).toHaveLength(golden.length);
    expect(golden.length).toBeGreaterThan(0);

    recording.forEach((frame, index) => {
      const expected = golden[index]!;
      const parsed = parseHeadFaceFrame(frame.raw, frame.timestampMs);

      expectClose(parsed, { timestampMs: expected.timestampMs, cues: expected.cues });
      expected.candidates.forEach((candidate) =>
        expect(safeParseAttentionRegionCandidate(candidate).success).toBe(true),
      );
    });
  });

  it("keeps the fixture set small enough for normal CI", () => {
    const totalBytes = FIXTURES.flatMap((name) => [
      `${name}.frames.json`,
      `${name}.golden.json`,
    ]).reduce((total, file) => total + statSync(join(fixturesDir, file)).size, 0);

    expect(totalBytes).toBeLessThan(20_000);
  });

  it("rejects malformed confidence before it reaches fusion", () => {
    expect(() =>
      parseHeadFaceFrame(
        {
          faces: [
            {
              id: "bad-face",
              confidence: 1.2,
              boundingBox: { x: 0.4, y: 0.2, width: 0.2, height: 0.3 },
              landmarks: {
                leftEye: [{ x: 0.46, y: 0.32 }],
                rightEye: [{ x: 0.56, y: 0.32 }],
                nose: [{ x: 0.51, y: 0.42 }],
              },
            },
          ],
        },
        0,
      ),
    ).toThrow("confidence");
  });
});
