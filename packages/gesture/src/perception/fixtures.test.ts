import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

import { type LandmarkFrame, LandmarkFrame as LandmarkFrameSchema } from "@handsoff/contracts";
import { describe, expect, it } from "vitest";

import { parseLandmarkFrame, type RawHandLandmarkerResult } from "./parse";

const fixturesDir = join(dirname(fileURLToPath(import.meta.url)), "../../fixtures");

interface Recorded {
  timestampMs: number;
  raw: RawHandLandmarkerResult;
}

const load = <T>(file: string): T => JSON.parse(readFileSync(join(fixturesDir, file), "utf8")) as T;

// The five recorded sequences the downstream gesture tickets test against (#29).
const FIXTURES = ["no-hand", "point", "hold", "cancel", "low-confidence"];

describe("recorded-frame fixtures", () => {
  it.each(FIXTURES)("%s: parser reconstructs every frame's golden exactly", (name) => {
    const recording = load<Recorded[]>(`${name}.frames.json`);
    const golden = load<LandmarkFrame[]>(`${name}.golden.json`);

    expect(recording).toHaveLength(golden.length);
    expect(golden.length).toBeGreaterThan(0);

    recording.forEach((frame, i) => {
      // Golden itself must be a valid contract frame...
      expect(() => LandmarkFrameSchema.parse(golden[i])).not.toThrow();
      // ...and the single shared parser must reconstruct it exactly from the raw.
      expect(parseLandmarkFrame(frame.raw, frame.timestampMs)).toEqual(golden[i]);
    });
  });
});
