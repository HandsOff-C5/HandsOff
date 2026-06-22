import type { FinalTranscript, TranscriptEvent } from "@handsoff/contracts";

// Endpointing: collapse one capture's transcript events into a single stable
// final utterance (#32, AD2).
//
// A provider may emit several `FinalTranscript`s during one push-to-talk hold —
// the on-device sidecar finalizes on natural pauses, AssemblyAI per turn — plus
// a stream of revised partials. The intent engine wants *one* stable utterance
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
  return { ...state, partial: event.text };
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
