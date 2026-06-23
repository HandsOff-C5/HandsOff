import type { PointingEvidence } from "@handsoff/contracts";

// A pointing-evidence sample stamped with the time it was observed (ms, any
// monotonic clock shared with the utterance window). The desktop buffers these
// as gesture/head pointing streams in, then aligns them to speech at fuse time.
export type TimedPointingEvidence = { at: number; evidence: PointingEvidence };

// The utterance's time span (e.g. final-transcript start/end), same clock as `at`.
export type UtteranceWindow = { startMs: number; endMs: number };

export type AlignOptions = {
  // How far before/after the utterance a pointing sample still counts. People
  // point slightly before and hold through the phrase, so the deictic gesture
  // rarely lines up exactly with the words. Default 750ms.
  toleranceMs?: number;
};

const DEFAULT_TOLERANCE_MS = 750;

// Select the pointing evidence that co-occurred with the utterance. Only
// evidence inside the tolerance-expanded window counts as "aligned" — stale
// pointing from seconds ago is intentionally dropped (AD5: clarify rather than
// hijack intent with old evidence; the #36 policy asks when this is empty).
// Within the window the latest sample per source wins (the point is usually held
// into the phrase). Output is ordered by timestamp ascending for a stable,
// replayable trail.
export function alignPointingEvidence(
  buffer: readonly TimedPointingEvidence[],
  utterance: UtteranceWindow,
  options: AlignOptions = {},
): PointingEvidence[] {
  if (buffer.length === 0) return [];

  const tolerance = options.toleranceMs ?? DEFAULT_TOLERANCE_MS;
  const lo = utterance.startMs - tolerance;
  const hi = utterance.endMs + tolerance;

  const inWindow = buffer.filter((sample) => sample.at >= lo && sample.at <= hi);

  // Keep the latest sample per source.
  const latestPerSource = new Map<PointingEvidence["source"], TimedPointingEvidence>();
  for (const sample of inWindow) {
    const current = latestPerSource.get(sample.evidence.source);
    if (!current || sample.at > current.at) {
      latestPerSource.set(sample.evidence.source, sample);
    }
  }

  return [...latestPerSource.values()].sort((a, b) => a.at - b.at).map((sample) => sample.evidence);
}
