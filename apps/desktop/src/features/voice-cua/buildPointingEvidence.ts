import type { FinalTranscript, PointingEvidence, SurfaceSnapshot } from "@handsoff/contracts";
import { bindTemporalDeixis, type AttentionWindow } from "@handsoff/intent";

import type { CaptureTrace } from "../capture-trace";
import type { HeadPointingSnapshot } from "../head-pointing/useHeadPointing";

// The live pointing signals read once at intent time. Gathered by the controller
// from the gesture/head pipelines (consolidated behind one `getPointingContext`
// getter) and handed to the pure builder below — keeping the fusion logic free
// of refs and React so it is unit-testable in isolation.
export interface PointingContext {
  // Locked referent from gesture (#35): a specific surface the camera held a
  // point on at intent time; null when nothing is locked.
  readonly gestureEvidence: PointingEvidence | null;
  // The live gesture cursor position (even without a locked referent); null when
  // no hands are present.
  readonly gestureCursor: { x: number; y: number } | null;
  // The most recent CLOSED capture trace (U5): the timestamped head + hand + word
  // streams for the just-finished utterance; null on a non-capture utterance.
  readonly captureTrace: CaptureTrace | null;
  // The pointable windows (surface + screen bounds) the binder ranks a head point
  // against and resolves a hand candidate's targetId to; empty when no layout has
  // been reported yet.
  readonly pointableWindows: readonly AttentionWindow[];
}

export interface BuiltPointingEvidence {
  readonly pointingEvidence: readonly PointingEvidence[];
  readonly surfaceCandidates: readonly SurfaceSnapshot[];
}

// Run the temporal binder (U6) over the just-closed capture trace + the final
// transcript's per-word timeline, returning the bound deictic referents as
// `fusion` PointingEvidence. Returns [] when there is no trace, no per-word
// timings, or no pointable windows to resolve a surface against — so the
// snapshot path stays the only signal (fallback). The words on the trace (sealed
// by the recorder at finalize) and on the final transcript are the same U4
// timeline; prefer the transcript's so a binder run never depends on recorder
// timing, falling back to the trace's words when the transcript omits them.
function bindUtterance(
  finalTranscript: FinalTranscript,
  context: PointingContext,
): readonly PointingEvidence[] {
  const trace = context.captureTrace;
  if (!trace) return [];
  const words = finalTranscript.words ?? trace.words;
  if (!words || words.length === 0) return [];
  const windows = context.pointableWindows;
  if (windows.length === 0) return [];

  const bindings = bindTemporalDeixis({
    words,
    headTrace: trace.headTrace,
    handTrace: trace.handTrace,
    windows,
  });
  return bindings
    .map((binding) => binding.evidence)
    .filter((evidence): evidence is PointingEvidence => evidence !== null);
}

// Combine every available pointing signal into one evidence list (combinative,
// not a priority hierarchy) and derive the deduplicated surface candidates from
// it. Pure: all live signals arrive via `context`, and the active-window
// fallback (the only async, driver-touching step) is supplied as a thunk that is
// awaited ONLY when no gesture/head/bound evidence exists, preserving the exact
// fallback behavior of the previous inline implementation.
export async function buildPointingEvidence(
  finalTranscript: FinalTranscript,
  context: PointingContext,
  headPointing: HeadPointingSnapshot | undefined,
  resolveFallbackSurface: () => Promise<SurfaceSnapshot>,
): Promise<BuiltPointingEvidence> {
  const gesture = context.gestureEvidence;
  const gestureCursor = context.gestureCursor;
  const headCandidates = headPointing?.candidates ?? [];

  // Combinative pointing evidence: combine all available signals rather than
  // using a priority hierarchy. Gesture referent, gesture cursor position,
  // and face tracker evidence are all included when available.
  const pointingEvidence: PointingEvidence[] = [];

  // Locked referent from gesture (highest signal quality — has a specific surface).
  if (gesture) {
    pointingEvidence.push(gesture);
  }
  // Gesture cursor position (even without a locked referent). Added when no
  // locked gesture referent already carries a cursor.
  if (gestureCursor && (!gesture || !gesture.cursor)) {
    pointingEvidence.push({
      source: "gesture",
      confidence: gesture ? gesture.confidence : 0.3,
      strategy: "wrist-ray-position",
      cursor: gestureCursor,
    });
  }
  // Face tracker cursor + head attention candidates.
  if (headPointing && headPointing.point) {
    pointingEvidence.push({
      source: "head",
      confidence: 0.5,
      strategy: "face-tracker-position",
      cursor: headPointing.point,
    });
  }
  for (const candidate of headCandidates) {
    pointingEvidence.push({
      source: "head",
      confidence: candidate.score,
      strategy: "head-neighborhood",
      surface: candidate.surface,
      ...(headPointing?.point && { cursor: headPointing.point }),
    });
  }
  // When head is present but no candidates came in yet, include a low-confidence
  // head entry so the intent engine still sees the face tracker signal.
  if (headPointing && headCandidates.length === 0) {
    pointingEvidence.push({
      source: "head",
      confidence: 0,
      strategy: "head-neighborhood-empty",
      ...(headPointing.point && { cursor: headPointing.point }),
    });
  }

  // Timestamped multi-target binding (U7): when the recorder handed back a trace
  // for this utterance AND the transcript carries per-word timings, align each
  // deictic word ("this"/"that") with the surface that was pointed at WHILE it
  // was spoken (U6), and prepend those bound referents as `fusion` evidence.
  // They lead the array so their surfaces win the dedup below (a temporally
  // bound deictic is the strongest target signal), and each distinct bound
  // surface becomes its own candidate — so "type X in this and Y in that"
  // reaches the loop with BOTH targets. When there is no trace/words (a
  // non-capture utterance) this contributes nothing and the single
  // end-of-speech snapshot above stays the sole signal — fallback preserved.
  const boundEvidence = bindUtterance(finalTranscript, context);
  if (boundEvidence.length > 0) {
    pointingEvidence.unshift(...boundEvidence);
  }

  // Fallback to active window only when no gesture, head, or bound evidence is
  // available.
  if (pointingEvidence.length === 0) {
    pointingEvidence.push({
      source: "cursor",
      confidence: 1,
      strategy: "active-window-current-cursor",
      surface: await resolveFallbackSurface(),
    });
  }

  // Deduplicated surface candidates from all evidence.
  const seenIds = new Set<string>();
  const surfaceCandidates = pointingEvidence
    .map((e) => e.surface)
    .filter((s): s is NonNullable<typeof s> => {
      if (!s) return false;
      if (seenIds.has(s.id)) return false;
      seenIds.add(s.id);
      return true;
    });

  return { pointingEvidence, surfaceCandidates };
}
