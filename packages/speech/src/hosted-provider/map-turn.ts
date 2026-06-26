import type {
  PartialTranscript,
  FinalTranscript,
  TranscriptEvent,
  TranscriptWord,
} from "@handsoff/contracts";

import type { AssemblyAiTurnMessage, AssemblyAiWord } from "./assemblyai-messages";

// Pure mapping from an AssemblyAI v3 `Turn` message to the `SttStream` contract's
// `TranscriptEvent` (#30, #31, AD2). No I/O — this is the deterministic core the
// provider is tested against.
//
// v3 has no transcript-level confidence, so we aggregate `words[].confidence`.
// Latency is the wall-clock gap between when the audio that produced the turn
// ended and when we received the event: `now - (sessionStartMs + lastWordEndMs)`.

export interface MapTurnTiming {
  // Epoch ms captured when the session's `Begin` message arrived. Word `start`/
  // `end` are relative to this.
  readonly sessionStartMs: number;
  // Epoch ms at which this turn was received (injected for determinism).
  readonly now: number;
}

// Mean of word confidences, or 1 when a turn carries no words yet (an empty
// interim). Confidence is clamped to [0, 1] defensively.
function meanConfidence(words: readonly AssemblyAiWord[]): number {
  if (words.length === 0) return 1;
  const sum = words.reduce((acc, word) => acc + word.confidence, 0);
  const mean = sum / words.length;
  return Math.min(1, Math.max(0, mean));
}

// End (ms from session start) of the last word in the turn, or 0 when empty.
function lastWordEndMs(words: readonly AssemblyAiWord[]): number {
  const last = words[words.length - 1];
  return last ? last.end : 0;
}

// Place each word's `start`/`end` (ms from session start) on the wall clock by
// adding `sessionStartMs`, yielding the epoch-ms timeline a downstream binder
// can align with head/hand pointing samples. Returns `undefined` when there are
// no words or the session start is unknown (a Turn before `Begin`), so the
// transcript simply omits `words` rather than carrying epoch-scale garbage.
function epochWords(
  words: readonly AssemblyAiWord[],
  sessionStartMs: number,
): ReadonlyArray<TranscriptWord> | undefined {
  if (words.length === 0 || sessionStartMs <= 0) return undefined;
  return words.map((word) => ({
    text: word.text,
    startMs: sessionStartMs + word.start,
    endMs: sessionStartMs + word.end,
    confidence: Math.min(1, Math.max(0, word.confidence)),
  }));
}

// Map one v3 `Turn` to a contract `TranscriptEvent`. `end_of_turn === false`
// yields a `PartialTranscript`; `true` yields a `FinalTranscript`.
export function mapTurn(turn: AssemblyAiTurnMessage, timing: MapTurnTiming): TranscriptEvent {
  const confidence = meanConfidence(turn.words);
  // Until `Begin` has set a real session start, word timings can't be placed on
  // the wall clock; report 0 rather than an epoch-scale garbage latency.
  const latencyMs =
    timing.sessionStartMs <= 0
      ? 0
      : Math.max(0, timing.now - (timing.sessionStartMs + lastWordEndMs(turn.words)));

  const words = epochWords(turn.words, timing.sessionStartMs);
  const base = {
    text: turn.transcript,
    confidence,
    latencyMs,
    receivedAt: timing.now,
    // Only attach `words` when we actually have an epoch timeline, so the
    // no-words / pre-Begin path leaves the field absent.
    ...(words ? { words } : {}),
  };

  if (turn.end_of_turn) {
    return { kind: "final", ...base } satisfies FinalTranscript;
  }
  return { kind: "partial", ...base } satisfies PartialTranscript;
}
