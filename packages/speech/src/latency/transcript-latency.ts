import type { FinalTranscript, TranscriptEvent } from "@handsoff/contracts";

export interface TranscriptLatencyRecord {
  readonly kind: "transcript-latency";
  readonly captureStartedAt: number;
  readonly finalReceivedAt: number;
  readonly captureToFinalMs: number;
  readonly finalTranscriptLatencyMs: number;
  readonly transcriptText: string;
  readonly eventCount: number;
}

export function recordTranscriptLatency(
  captureStartedAt: number,
  events: readonly TranscriptEvent[],
): TranscriptLatencyRecord | null {
  const final = lastFinal(events);
  if (!final) return null;

  const captureToFinalMs = final.receivedAt - captureStartedAt;
  if (captureToFinalMs < 0) {
    throw new RangeError("Final transcript was received before capture started");
  }

  return {
    kind: "transcript-latency",
    captureStartedAt,
    finalReceivedAt: final.receivedAt,
    captureToFinalMs,
    finalTranscriptLatencyMs: final.latencyMs,
    transcriptText: final.text,
    eventCount: events.length,
  };
}

function lastFinal(events: readonly TranscriptEvent[]): FinalTranscript | null {
  for (let index = events.length - 1; index >= 0; index -= 1) {
    const event = events[index];
    if (event?.kind === "final") return event;
  }
  return null;
}
