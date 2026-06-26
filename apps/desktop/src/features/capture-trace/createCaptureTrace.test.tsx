import type { PointingCandidate, TranscriptWord } from "@handsoff/contracts";
import { describe, expect, it } from "vitest";

import { createCaptureTrace, type CaptureTraceClocks } from "./createCaptureTrace";

// Two independent, controllable clocks: `now` is the epoch clock (head + word
// stamps), `perf` is the monotonic `performance.now`-style clock the hand stream
// uses. They are deliberately offset so the normalization math is observable.
function clocks(): CaptureTraceClocks & {
  setNow: (v: number) => void;
  setPerf: (v: number) => void;
} {
  let nowMs = 1_000_000; // epoch ms
  let perfMs = 5_000; // performance.now ms (arbitrary origin)
  return {
    now: () => nowMs,
    performanceNow: () => perfMs,
    setNow: (v) => (nowMs = v),
    setPerf: (v) => (perfMs = v),
  };
}

const candidate: PointingCandidate = {
  targetId: "win-notes",
  confidence: 0.8,
  calibrationQuality: "good",
};

const words: readonly TranscriptWord[] = [
  { text: "type", startMs: 1_000_100, endMs: 1_000_300, confidence: 0.9 },
  { text: "this", startMs: 1_000_400, endMs: 1_000_700, confidence: 0.8 },
];

describe("createCaptureTrace — lifecycle", () => {
  it("is not recording until start() and stop() returns null when never started", () => {
    const recorder = createCaptureTrace(clocks());
    expect(recorder.recording).toBe(false);
    expect(recorder.stop()).toBeNull();
  });

  it("reports recording between start() and stop()", () => {
    const recorder = createCaptureTrace(clocks());
    recorder.start();
    expect(recorder.recording).toBe(true);
    recorder.stop();
    expect(recorder.recording).toBe(false);
  });

  it("ignores samples recorded while no window is open", () => {
    const recorder = createCaptureTrace(clocks());
    recorder.recordHead({ x: 1, y: 2, confidence: 1, tsMs: 1_000_001 });
    recorder.recordHand({ frameTimestampMs: 5_001, x: 3, y: 4, candidate: null, phase: "idle" });
    recorder.start();
    const trace = recorder.stop();
    expect(trace?.headTrace).toEqual([]);
    expect(trace?.handTrace).toEqual([]);
  });
});

describe("createCaptureTrace — windowing", () => {
  it("retains head/hand/word samples within the window, in time order", () => {
    const c = clocks();
    const recorder = createCaptureTrace(c);
    // start at epoch 1_000_000 / perf 5_000.
    recorder.start();

    // Head samples (epoch ms) arrive out of order; the trace sorts them.
    recorder.recordHead({ x: 10, y: 10, confidence: 0.7, tsMs: 1_000_500 });
    recorder.recordHead({ x: 20, y: 20, confidence: 0.9, tsMs: 1_000_200 });

    // Hand samples (perf ms): perf 5_100 and 5_300 → epoch 1_000_100 / 1_000_300.
    recorder.recordHand({ frameTimestampMs: 5_300, x: 3, y: 3, candidate, phase: "locked" });
    recorder.recordHand({ frameTimestampMs: 5_100, x: 1, y: 1, candidate: null, phase: "idle" });

    recorder.setWords(words);

    // stop after all samples (epoch 1_001_000).
    c.setNow(1_001_000);
    const trace = recorder.stop();

    expect(trace?.headTrace.map((s) => s.tsMs)).toEqual([1_000_200, 1_000_500]);
    expect(trace?.handTrace.map((s) => s.tsMs)).toEqual([1_000_100, 1_000_300]);
    expect(trace?.words).toEqual(words);
  });

  it("excludes head samples whose epoch stamp falls outside [start, stop]", () => {
    const c = clocks();
    const recorder = createCaptureTrace(c);
    recorder.start(); // epoch 1_000_000

    recorder.recordHead({ x: 0, y: 0, confidence: 1, tsMs: 999_999 }); // before start
    recorder.recordHead({ x: 1, y: 1, confidence: 1, tsMs: 1_000_500 }); // inside
    recorder.recordHead({ x: 2, y: 2, confidence: 1, tsMs: 1_002_000 }); // after stop

    c.setNow(1_001_000); // stop boundary
    const trace = recorder.stop();
    expect(trace?.headTrace.map((s) => s.tsMs)).toEqual([1_000_500]);
  });

  it("excludes a hand frame whose NORMALIZED stamp lands after the window closes", () => {
    const c = clocks();
    const recorder = createCaptureTrace(c);
    recorder.start(); // epoch 1_000_000 / perf 5_000

    recorder.recordHand({ frameTimestampMs: 5_400, x: 1, y: 1, candidate: null, phase: "idle" }); // → 1_000_400, inside
    recorder.recordHand({ frameTimestampMs: 6_000, x: 2, y: 2, candidate: null, phase: "idle" }); // → 1_001_000, outside

    c.setNow(1_000_500); // stop boundary < second sample's normalized stamp
    const trace = recorder.stop();
    expect(trace?.handTrace.map((s) => s.tsMs)).toEqual([1_000_400]);
  });
});

describe("createCaptureTrace — clock normalization", () => {
  it("maps a hand frame's performance.now stamp to epoch ms via the start offset", () => {
    const c = clocks();
    const recorder = createCaptureTrace(c);
    recorder.start(); // epoch 1_000_000 pinned to perf 5_000

    // A frame 250ms into the window: perf 5_250 → epoch 1_000_000 + (5_250 - 5_000).
    recorder.recordHand({ frameTimestampMs: 5_250, x: 9, y: 9, candidate, phase: "candidate" });

    c.setNow(1_001_000);
    const trace = recorder.stop();
    expect(trace?.handTrace[0]?.tsMs).toBe(1_000_250);
    // The screen point + candidate + phase survive unchanged.
    expect(trace?.handTrace[0]).toMatchObject({ x: 9, y: 9, candidate, phase: "candidate" });
  });

  it("uses the offset captured at THIS start, not a stale one", () => {
    const c = clocks();
    const recorder = createCaptureTrace(c);

    recorder.start();
    recorder.stop();

    // Second window starts at a different epoch/perf pair.
    c.setNow(2_000_000);
    c.setPerf(8_000);
    recorder.start();
    recorder.recordHand({ frameTimestampMs: 8_100, x: 0, y: 0, candidate: null, phase: "idle" });
    c.setNow(2_001_000);
    const trace = recorder.stop();
    // perf 8_100 → epoch 2_000_000 + 100.
    expect(trace?.handTrace[0]?.tsMs).toBe(2_000_100);
  });
});

describe("createCaptureTrace — edge cases", () => {
  it("returns an empty hand trace when no hand sample was recorded", () => {
    const c = clocks();
    const recorder = createCaptureTrace(c);
    recorder.start();
    recorder.recordHead({ x: 1, y: 1, confidence: 1, tsMs: 1_000_100 });
    c.setNow(1_001_000);
    const trace = recorder.stop();
    expect(trace?.handTrace).toEqual([]);
    expect(trace?.headTrace).toHaveLength(1);
  });

  it("closes the window cleanly when toggled off mid-utterance (empty words)", () => {
    const c = clocks();
    const recorder = createCaptureTrace(c);
    recorder.start();
    recorder.recordHand({ frameTimestampMs: 5_100, x: 1, y: 1, candidate, phase: "locked" });
    // No setWords — utterance never finalized.
    c.setNow(1_000_500);
    const trace = recorder.stop();
    expect(trace?.words).toEqual([]);
    expect(trace?.handTrace).toHaveLength(1);
    expect(recorder.recording).toBe(false);
  });

  it("a fresh start() discards the prior window's buffers", () => {
    const c = clocks();
    const recorder = createCaptureTrace(c);
    recorder.start();
    recorder.recordHead({ x: 1, y: 1, confidence: 1, tsMs: 1_000_100 });
    // Re-arm without stop: the earlier head sample must not leak into the new trace.
    c.setNow(1_002_000);
    c.setPerf(7_000);
    recorder.start();
    c.setNow(1_003_000);
    const trace = recorder.stop();
    expect(trace?.headTrace).toEqual([]);
  });
});
