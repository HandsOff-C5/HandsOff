import type { PointingEvidence } from "@handsoff/contracts";

// STUB — red phase. The failing test demands the real selector.
export type TimedPointingEvidence = { at: number; evidence: PointingEvidence };
export type UtteranceWindow = { startMs: number; endMs: number };
export type AlignOptions = { toleranceMs?: number };

export function alignPointingEvidence(
  buffer: readonly TimedPointingEvidence[],
  utterance: UtteranceWindow,
  options: AlignOptions = {},
): PointingEvidence[] {
  void buffer;
  void utterance;
  void options;
  return [];
}
