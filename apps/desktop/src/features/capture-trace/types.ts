import type { GestureState, PointingCandidate, TranscriptWord } from "@handsoff/contracts";

// Timestamped pointing traces recorded for one capture-mode window (U5).
//
// The three streams the temporal binder (U6) consumes are normalized to ONE
// epoch-ms clock here, so a deictic word's `[startMs, endMs]` can be bracketed
// against the head/hand sample that was live while it was spoken. Head and word
// stamps are already epoch ms on the wire; the hand stream is `performance.now`
// based and is converted to epoch ms by the recorder (see createCaptureTrace).

// One head-pointing sample: the projected screen point the head was aimed at and
// the host's confidence in it, stamped in epoch ms.
export interface HeadTraceSample {
  readonly x: number;
  readonly y: number;
  readonly confidence: number;
  readonly tsMs: number;
}

// One hand-pointing sample: the smoothed screen-space pointer this frame, the
// loop's candidate (null when no surface/hand), the FSM phase, and the epoch-ms
// timestamp (already normalized off `performance.now`).
export interface HandTraceSample {
  readonly x: number;
  readonly y: number;
  readonly candidate: PointingCandidate | null;
  readonly phase: GestureState;
  readonly tsMs: number;
}

// The recorded capture window: three streams sharing one epoch-ms clock.
export interface CaptureTrace {
  readonly headTrace: readonly HeadTraceSample[];
  readonly handTrace: readonly HandTraceSample[];
  readonly words: readonly TranscriptWord[];
}
