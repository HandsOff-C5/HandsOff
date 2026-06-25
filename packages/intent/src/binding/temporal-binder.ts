import type {
  GestureState,
  PointingCandidate,
  PointingEvidence,
  SurfaceSnapshot,
  TranscriptWord,
} from "@handsoff/contracts";

import { rankAttentionCandidates, type AttentionWindow } from "../attention/candidates";

// Temporal deixis binder (U6) — PURE.
//
// One spoken utterance can point at several surfaces in turn ("type Laura in
// THIS, and hello in THAT"). Given the per-word transcript timeline (U4) and the
// head/hand pointing traces recorded during the same capture window (U5), all on
// one epoch-ms clock, this binds each deictic word to the surface that was
// pointed at WHILE THAT WORD WAS SPOKEN — before the model is called.
//
// For each deictic word it picks the pointing sample whose timestamp brackets
// `[word.startMs, word.endMs]`, preferring a locked hand referent over a hand
// cursor over a head point (and, within a tier, higher confidence). When no
// sample brackets the word exactly it falls back to the nearest sample inside a
// gesture-PRECEDES-speech tolerance window (people point a beat before they
// say "this"). A word with no nearby sample is left UNBOUND rather than
// mis-bound to the wrong window.

// The deictic tokens that anchor to a pointed-at surface.
export const DEICTIC_WORDS = ["this", "that", "here", "there", "these", "those"] as const;
const DEICTIC_SET = new Set<string>(DEICTIC_WORDS);

// People point a beat before they say the deictic word; allow a gesture up to
// this far BEFORE the word to bind when nothing brackets it exactly. Bounded so a
// stale gesture from much earlier never binds.
export const DEFAULT_GESTURE_PRECEDES_TOLERANCE_MS = 1500;

// Head/hand trace samples the binder consumes. Defined here (not imported from
// the desktop recorder) so `packages/intent` keeps its contracts-only boundary;
// the recorder's `HeadTraceSample`/`HandTraceSample` are structurally these.
export interface HeadTraceSample {
  readonly x: number;
  readonly y: number;
  readonly confidence: number;
  readonly tsMs: number;
}

export interface HandTraceSample {
  readonly x: number;
  readonly y: number;
  readonly candidate: PointingCandidate | null;
  readonly phase: GestureState;
  readonly tsMs: number;
}

export interface TemporalBindInput {
  readonly words: readonly TranscriptWord[];
  readonly headTrace: readonly HeadTraceSample[];
  readonly handTrace: readonly HandTraceSample[];
  // Pointable windows (surface + screen bounds) to rank a head point against and
  // to resolve a hand candidate's `targetId` to its surface snapshot.
  readonly windows: readonly AttentionWindow[];
  // Gesture-precedes-speech tolerance (ms). Defaults to ~1.5s.
  readonly toleranceMs?: number;
  // Neighborhood radius (px) handed to the head-point ranker.
  readonly headRadius?: number;
}

// One deictic word's binding outcome. `evidence` is the bound pointing evidence,
// or null when no nearby sample backed the word (→ clarification downstream).
export interface TemporalBinding {
  readonly word: string;
  readonly startMs: number;
  readonly endMs: number;
  readonly evidence: PointingEvidence | null;
}

// Strip surrounding punctuation and lowercase, so "this," / "This" match.
function normalizeWord(text: string): string {
  return text.toLowerCase().replace(/[^\p{L}]/gu, "");
}

export function isDeicticWord(text: string): boolean {
  return DEICTIC_SET.has(normalizeWord(text));
}

// True when `tsMs` falls inside [start, end], or inside the gesture-precedes
// window [start - tolerance, end] used only as a fallback.
function withinWindow(tsMs: number, startMs: number, endMs: number, toleranceMs: number): boolean {
  return tsMs >= startMs - toleranceMs && tsMs <= endMs;
}

function bracketsExactly(tsMs: number, startMs: number, endMs: number): boolean {
  return tsMs >= startMs && tsMs <= endMs;
}

// Pick the best hand sample for a word: prefer one that brackets exactly over one
// in the tolerance window, prefer `locked` phase over any other, then higher
// candidate confidence, then the sample nearest the word's start. Only samples
// that carry a candidate (a resolved surface) are eligible.
function pickHandSample(
  samples: readonly HandTraceSample[],
  startMs: number,
  endMs: number,
  toleranceMs: number,
): HandTraceSample | null {
  const eligible = samples.filter(
    (s) => s.candidate !== null && withinWindow(s.tsMs, startMs, endMs, toleranceMs),
  );
  if (eligible.length === 0) return null;

  const rank = (s: HandTraceSample): [number, number, number, number] => [
    bracketsExactly(s.tsMs, startMs, endMs) ? 1 : 0,
    s.phase === "locked" ? 1 : 0,
    s.candidate?.confidence ?? 0,
    -Math.abs(s.tsMs - startMs),
  ];
  return [...eligible].sort((a, b) => compareRank(rank(b), rank(a)))[0] ?? null;
}

// Pick the best head sample for a word by the same exact-vs-tolerance preference,
// then proximity to the word's start (head confidence feeds the ranker, not this
// choice — the ranker turns the point into a scored surface).
function pickHeadSample(
  samples: readonly HeadTraceSample[],
  startMs: number,
  endMs: number,
  toleranceMs: number,
): HeadTraceSample | null {
  const eligible = samples.filter((s) => withinWindow(s.tsMs, startMs, endMs, toleranceMs));
  if (eligible.length === 0) return null;

  const rank = (s: HeadTraceSample): [number, number] => [
    bracketsExactly(s.tsMs, startMs, endMs) ? 1 : 0,
    -Math.abs(s.tsMs - startMs),
  ];
  return [...eligible].sort((a, b) => compareRank(rank(b), rank(a)))[0] ?? null;
}

// Lexicographic compare of fixed-length numeric rank tuples (higher is better).
function compareRank(a: readonly number[], b: readonly number[]): number {
  for (let i = 0; i < a.length; i += 1) {
    const diff = (a[i] ?? 0) - (b[i] ?? 0);
    if (diff !== 0) return diff;
  }
  return 0;
}

function surfaceForTargetId(
  targetId: string,
  windows: readonly AttentionWindow[],
): SurfaceSnapshot | null {
  return windows.find((w) => w.surface.id === targetId)?.surface ?? null;
}

function bindWord(word: TranscriptWord, input: TemporalBindInput): TemporalBinding {
  const toleranceMs = input.toleranceMs ?? DEFAULT_GESTURE_PRECEDES_TOLERANCE_MS;
  const base = { word: normalizeWord(word.text), startMs: word.startMs, endMs: word.endMs };

  // Tier 1+2: hand lock / hand cursor.
  const hand = pickHandSample(input.handTrace, word.startMs, word.endMs, toleranceMs);
  if (hand && hand.candidate) {
    // Prefer the candidate's exact resolved surface (when the gesture lane already
    // resolved a window id). When that targetId doesn't match a pointable window
    // — e.g. the lane resolved a DISPLAY id while the windows are real app windows
    // — fall back to the frontmost window under the hand point, the same
    // point→window resolution the head tier uses. This keeps the precise hand
    // (the primary modality) bound to a real window instead of dropping to a
    // whole display.
    const surface =
      surfaceForTargetId(hand.candidate.targetId, input.windows) ??
      rankAttentionCandidates({ x: hand.x, y: hand.y }, input.windows, {
        ...(input.headRadius !== undefined ? { radius: input.headRadius } : {}),
      })[0]?.surface ??
      null;
    if (surface) {
      return {
        ...base,
        evidence: {
          source: "fusion",
          confidence: hand.candidate.confidence,
          strategy: `temporal-bind:${base.word}@${hand.tsMs}`,
          surface,
        },
      };
    }
  }

  // Tier 3: head point, ranked into a scored surface.
  const head = pickHeadSample(input.headTrace, word.startMs, word.endMs, toleranceMs);
  if (head) {
    const ranked = rankAttentionCandidates({ x: head.x, y: head.y }, input.windows, {
      ...(input.headRadius !== undefined ? { radius: input.headRadius } : {}),
    });
    const top = ranked[0];
    if (top) {
      return {
        ...base,
        evidence: {
          source: "fusion",
          confidence: top.score,
          strategy: `temporal-bind:${base.word}@${head.tsMs}`,
          surface: top.surface,
        },
      };
    }
  }

  // No nearby pointing sample resolved a surface — leave it unbound.
  return { ...base, evidence: null };
}

// Bind every deictic word in the utterance to the surface pointed at while it was
// spoken. Words are returned in transcript order; non-deictic words are skipped.
export function bindTemporalDeixis(input: TemporalBindInput): readonly TemporalBinding[] {
  return input.words.filter((w) => isDeicticWord(w.text)).map((word) => bindWord(word, input));
}
