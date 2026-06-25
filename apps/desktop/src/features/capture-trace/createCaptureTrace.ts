import type { GestureState, PointingCandidate, TranscriptWord } from "@handsoff/contracts";

import type { CaptureTrace, HandTraceSample, HeadTraceSample } from "./types";

// Capture-trace recorder (U5).
//
// Records the head, hand, and word streams for exactly one capture-mode window
// and hands them back, on one epoch-ms clock, when the window closes. The
// recorder is the pure core: it owns the buffering, the windowing, and — the
// load-bearing part — the clock normalization. The thin shell (Dashboard) wires
// the `stt://head` subscription and the CameraPanel's `onGestureSample` callback
// into `recordHead`/`recordHand`, and the capture hotkey's onStart/onStop edges
// into `start`/`stop`.
//
// ONE CLOCK. Head and word timestamps are epoch ms already; hand-sample
// timestamps are `performance.now()` based (a monotonic clock with an arbitrary
// origin). At `start()` we capture an (epochAtStart, performanceAtStart) pair and
// convert every hand stamp to epoch ms via that offset, so all three streams end
// up on the same timeline the binder can align against.

// A head sample as it arrives off `stt://head` — already epoch-ms stamped.
export interface HeadPointInput {
  readonly x: number;
  readonly y: number;
  readonly confidence: number;
  readonly tsMs: number;
}

// A hand sample as it arrives off CameraPanel.onGestureSample — `performance.now`
// stamped (`frameTimestampMs`), converted to epoch ms on the way in.
export interface HandSampleInput {
  readonly frameTimestampMs: number;
  readonly x: number;
  readonly y: number;
  readonly candidate: PointingCandidate | null;
  readonly phase: GestureState;
}

export interface CaptureTraceRecorder {
  // Open a fresh window: pin the clock pair and discard any prior buffers. A
  // second `start()` without a `stop()` simply re-pins and re-arms.
  start(): void;
  // Record a head sample. Ignored when no window is open.
  recordHead(sample: HeadPointInput): void;
  // Record a hand sample. Ignored when no window is open.
  recordHand(sample: HandSampleInput): void;
  // Set/replace the per-word epoch-ms timeline (from the final transcript, U4).
  // Ignored when no window is open.
  setWords(words: readonly TranscriptWord[]): void;
  // Close the window and return the recorded trace, windowed to [start, stop] and
  // ordered by timestamp. Returns null when no window was open.
  stop(): CaptureTrace | null;
  readonly recording: boolean;
}

export interface CaptureTraceClocks {
  // Epoch-ms clock (Date.now in production; injected for deterministic tests).
  readonly now: () => number;
  // Monotonic clock matching the hand-sample `frameTimestampMs` origin
  // (performance.now in production; injected for tests).
  readonly performanceNow: () => number;
}

interface OpenWindow {
  readonly epochAtStart: number;
  readonly performanceAtStart: number;
  readonly head: HeadTraceSample[];
  readonly hand: HandTraceSample[];
  words: readonly TranscriptWord[];
}

export function createCaptureTrace(clocks: CaptureTraceClocks): CaptureTraceRecorder {
  let open: OpenWindow | null = null;

  return {
    get recording(): boolean {
      return open !== null;
    },

    start(): void {
      open = {
        epochAtStart: clocks.now(),
        performanceAtStart: clocks.performanceNow(),
        head: [],
        hand: [],
        words: [],
      };
    },

    recordHead(sample: HeadPointInput): void {
      if (!open) return;
      open.head.push({
        x: sample.x,
        y: sample.y,
        confidence: sample.confidence,
        tsMs: sample.tsMs,
      });
    },

    recordHand(sample: HandSampleInput): void {
      if (!open) return;
      // Normalize the monotonic frame stamp onto the epoch clock pinned at start.
      const tsMs = open.epochAtStart + (sample.frameTimestampMs - open.performanceAtStart);
      open.hand.push({
        x: sample.x,
        y: sample.y,
        candidate: sample.candidate,
        phase: sample.phase,
        tsMs,
      });
    },

    setWords(words: readonly TranscriptWord[]): void {
      if (!open) return;
      open.words = words;
    },

    stop(): CaptureTrace | null {
      if (!open) return null;
      const epochAtStop = clocks.now();
      const closed = open;
      open = null;

      // Window to [start, stop] on the shared epoch clock and order by time, so a
      // late head event that fired after the window closed (or a hand frame whose
      // normalized stamp lands outside it) is dropped rather than mis-aligned.
      const inWindow = (tsMs: number): boolean =>
        tsMs >= closed.epochAtStart && tsMs <= epochAtStop;

      const headTrace = closed.head.filter((s) => inWindow(s.tsMs)).sort((a, b) => a.tsMs - b.tsMs);
      const handTrace = closed.hand.filter((s) => inWindow(s.tsMs)).sort((a, b) => a.tsMs - b.tsMs);

      return { headTrace, handTrace, words: closed.words };
    },
  };
}
