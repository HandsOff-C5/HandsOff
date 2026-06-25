import type { FinalTranscript, TranscriptEvent } from "@handsoff/contracts";

// Endpointing: collapse one capture's transcript events into a single stable
// final utterance (#32, AD2).
//
// A provider may emit several `FinalTranscript`s during one push-to-talk hold —
// on-device native recognition finalizes on natural pauses, AssemblyAI per turn —
// plus a stream of revised partials. The intent engine wants *one* stable utterance
// per capture ("one utterance becomes one final transcript"), so the scoped plan
// is built from the whole spoken command, not a mid-sentence fragment.
//
// This module is pure: `foldUtterance` accumulates events into an immutable
// `UtteranceState`, and `endpointUtterance` renders that state into the single
// final when capture ends. The push-to-talk controller owns the lifecycle; this
// owns the text/metadata math, so both stay independently testable.

export interface UtteranceState {
  // Stable finals seen so far, in arrival order.
  readonly finals: readonly FinalTranscript[];
  // The latest interim partial — the unfinalized tail of speech. Reset whenever
  // a final lands, since the final supersedes it.
  readonly partial: string;
}

export const EMPTY_UTTERANCE: UtteranceState = { finals: [], partial: "" };

// Fold one provider transcript event into the in-progress utterance. Error
// events are not transcript text and are handled by the controller, not here.
export function foldUtterance(state: UtteranceState, event: TranscriptEvent): UtteranceState {
  if (event.kind === "final") {
    return { finals: [...state.finals, event], partial: "" };
  }
  // When the provider starts a new utterance after a natural pause, it may
  // simply emit a new partial without first emitting a final for the previous
  // speech. Detect this reset by comparing the leading prefix of the incoming
  // partial against the current one: if they don't share a common prefix, the
  // provider has moved to a completely new utterance and the current partial
  // must be checkpointed as a synthetic final before being replaced.
  if (!isRevisionOfSameUtterance(state.partial, event.text)) {
    const syntheticFinal: FinalTranscript = {
      kind: "final",
      text: state.partial.trim(),
      confidence: 0,
      latencyMs: 0,
      receivedAt: event.receivedAt,
    };
    return { finals: [...state.finals, syntheticFinal], partial: event.text };
  }
  return { ...state, partial: event.text };
}

// Returns true when `next` is a revision or extension of the same utterance as
// `prev` (they share a common leading prefix). Returns false when the provider
// appears to have reset to a brand-new utterance.
function isRevisionOfSameUtterance(prev: string, next: string): boolean {
  const a = prev.trim().toLowerCase();
  const b = next.trim().toLowerCase();
  // Empty strings on either side mean there is nothing to checkpoint.
  if (a.length === 0 || b.length === 0) return true;
  const n = Math.min(a.length, b.length, 20);
  return a.slice(0, n) === b.slice(0, n);
}

export interface EndpointOptions {
  // Epoch ms stamped on the emitted final — when capture endpointed.
  readonly receivedAt: number;
  // On manual push-to-talk release the provider may not have finalized the last
  // words yet, so include the trailing partial as the utterance tail. When the
  // provider signalled end-of-speech itself, the finals are already complete and
  // this should be false.
  readonly includeTrailingPartial: boolean;
}

// Render the accumulated state into the single stable final utterance, or `null`
// when nothing intelligible was captured (silence, or cancelled mid-word).
export function endpointUtterance(
  state: UtteranceState,
  options: EndpointOptions,
): FinalTranscript | null {
  const segments = state.finals.map((final) => final.text.trim()).filter(Boolean);
  if (options.includeTrailingPartial) {
    const tail = state.partial.trim();
    if (tail) segments.push(tail);
  }

  const text = segments.join(" ").replace(/\s+/g, " ").trim();
  if (!text) return null;

  return {
    kind: "final",
    text,
    // The utterance is only as confident as its weakest stable segment; a
    // partial-only tail carries no provider confidence (treated as 0).
    confidence: aggregateConfidence(state.finals),
    // Report the slowest contributing segment's latency as the utterance's
    // end-to-end latency — the worst case the user actually waited on.
    latencyMs: aggregateLatency(state.finals),
    receivedAt: options.receivedAt,
  };
}

function aggregateConfidence(finals: readonly FinalTranscript[]): number {
  if (finals.length === 0) return 0;
  return finals.reduce((min, final) => Math.min(min, final.confidence), Number.POSITIVE_INFINITY);
}

function aggregateLatency(finals: readonly FinalTranscript[]): number {
  return finals.reduce((max, final) => Math.max(max, final.latencyMs), 0);
}
