// Regenerate the recorded-frame fixtures for the gesture pipeline (#29).
//
// The GOLDEN (`*.golden.json`) is the authored source of truth — a sequence of
// already-normalized `LandmarkFrame`s. The RAW recording (`*.frames.json`) is
// mechanically DE-normalized from the golden (handedness split into its own
// list, exactly as MediaPipe emits it). The parser's job is to reconstruct the
// golden from the raw, so `parseLandmarkFrame(raw) deepEqual golden` is a real
// check — the golden is never produced by the parser under test.
//
// Synthetic for now; re-record from real `@mediapipe/tasks-vision` output once
// #25 lands (see docs/TODO.md). Run: `node packages/gesture/fixtures/build-fixtures.mjs`.
import { writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));

// 21 deterministic, distinct landmarks for a given hand/frame seed. Values stay
// inside the contract ranges (x/y in [0,1], visibility in [0,1]).
const hand = (seed, handedness, score, visibility) => ({
  handedness,
  score,
  landmarks: Array.from({ length: 21 }, (_, i) => ({
    x: Number((((seed * 7 + i * 3) % 100) / 100).toFixed(3)),
    y: Number((((seed * 13 + i * 5) % 100) / 100).toFixed(3)),
    z: Number(((i - 10) / 100).toFixed(3)),
    visibility,
  })),
});

// Each fixture is a named sequence of golden frames (10 fps → +100ms per frame).
const frames = (...handsPerFrame) =>
  handsPerFrame.map((hands, f) => ({ timestampMs: f * 100, hands }));

const FIXTURES = {
  // No hand in view across the sequence — the empty-hands path.
  "no-hand": frames([], []),
  // A single right hand pointing, steady high confidence.
  point: frames(
    [hand(1, "Right", 0.92, 0.96)],
    [hand(2, "Right", 0.93, 0.97)],
    [hand(3, "Right", 0.94, 0.98)],
  ),
  // Right hand held still long enough to dwell-lock (#27/#28 consume this).
  hold: frames(
    [hand(5, "Right", 0.95, 0.99)],
    [hand(5, "Right", 0.95, 0.99)],
    [hand(5, "Right", 0.95, 0.99)],
    [hand(5, "Right", 0.95, 0.99)],
  ),
  // A cancel gesture: hand present, then a distinct pose change.
  cancel: frames(
    [hand(7, "Left", 0.9, 0.95)],
    [hand(8, "Left", 0.9, 0.95)],
    [hand(21, "Left", 0.91, 0.96)],
  ),
  // Low-confidence detection — should surface as poor/clarification downstream.
  "low-confidence": frames([hand(9, "Right", 0.31, 0.4)], [hand(10, "Right", 0.28, 0.35)]),
};

// De-normalize a golden frame back to the raw MediaPipe shape it was recorded from.
const toRaw = (frame) => ({
  landmarks: frame.hands.map((h) => h.landmarks.map((l) => ({ ...l }))),
  handednesses: frame.hands.map((h) => [{ categoryName: h.handedness, score: h.score }]),
});

for (const [name, golden] of Object.entries(FIXTURES)) {
  const recording = golden.map((frame) => ({ timestampMs: frame.timestampMs, raw: toRaw(frame) }));
  writeFileSync(join(here, `${name}.golden.json`), JSON.stringify(golden, null, 2) + "\n");
  writeFileSync(join(here, `${name}.frames.json`), JSON.stringify(recording, null, 2) + "\n");
}
