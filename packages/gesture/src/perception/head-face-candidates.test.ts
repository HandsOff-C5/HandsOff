import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

import { safeParseAttentionRegionCandidate } from "@handsoff/contracts";
import { describe, expect, it } from "vitest";

import { headFaceAttentionCandidates, type HeadFaceAttentionRegion } from "./head-face-candidates";
import { parseHeadFaceFrame, type HeadFaceFrame, type RawHeadFaceFrame } from "./head-face";

const fixturesDir = join(dirname(fileURLToPath(import.meta.url)), "../../fixtures");

interface Recorded {
  timestampMs: number;
  raw: RawHeadFaceFrame;
}

interface Golden extends HeadFaceFrame {
  candidates: ReturnType<typeof headFaceAttentionCandidates>;
}

const load = <T>(file: string): T => JSON.parse(readFileSync(join(fixturesDir, file), "utf8")) as T;

const regions: HeadFaceAttentionRegion[] = [
  {
    region: "center",
    surface: {
      id: "window-center",
      title: "Editor",
      app: "Cursor",
      pid: 101,
      windowId: 7,
      availability: "available",
      accessStatus: "accessible",
    },
  },
  {
    region: "right",
    surface: {
      id: "window-right",
      title: "Preview",
      app: "Safari",
      pid: 202,
      windowId: 9,
      availability: "available",
      accessStatus: "accessible",
    },
  },
];

const FIXTURES = [
  "head-face-present",
  "head-face-none",
  "head-face-off-axis",
  "head-face-low-confidence",
] as const;

describe("head/face attention candidates", () => {
  it.each(FIXTURES)("%s: maps parsed cues to golden candidate records", (name) => {
    const recording = load<Recorded[]>(`${name}.frames.json`);
    const golden = load<Golden[]>(`${name}.golden.json`);

    recording.forEach((frame, index) => {
      const parsed = parseHeadFaceFrame(frame.raw, frame.timestampMs);
      const candidates = headFaceAttentionCandidates(parsed, regions);

      expect(candidates).toEqual(golden[index]!.candidates);
      candidates.forEach((candidate) =>
        expect(safeParseAttentionRegionCandidate(candidate).success).toBe(true),
      );
    });
  });
});
