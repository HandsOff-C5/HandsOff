import type { TranscriptEvent } from "@handsoff/contracts";
import { describe, expect, it } from "vitest";

import { recordTranscriptLatency } from "./transcript-latency";

describe("recordTranscriptLatency", () => {
  it("records capture-start to the last final transcript", () => {
    const events: readonly TranscriptEvent[] = [
      { kind: "partial", text: "approve", confidence: 0.5, latencyMs: 35, receivedAt: 1100 },
      {
        kind: "final",
        text: "approve the plan",
        confidence: 0.96,
        latencyMs: 82,
        receivedAt: 1280,
      },
      {
        kind: "final",
        text: "and continue",
        confidence: 0.9,
        latencyMs: 110,
        receivedAt: 1395,
      },
    ];

    expect(recordTranscriptLatency(1000, events)).toEqual({
      kind: "transcript-latency",
      captureStartedAt: 1000,
      finalReceivedAt: 1395,
      captureToFinalMs: 395,
      finalTranscriptLatencyMs: 110,
      transcriptText: "and continue",
      eventCount: 3,
    });
  });

  it("returns null when the capture has no final transcript", () => {
    expect(
      recordTranscriptLatency(1000, [
        { kind: "partial", text: "approve", confidence: 0.5, latencyMs: 35, receivedAt: 1100 },
      ]),
    ).toBeNull();
  });

  it("rejects a final transcript timestamp before capture start", () => {
    expect(() =>
      recordTranscriptLatency(1000, [
        {
          kind: "final",
          text: "approve the plan",
          confidence: 0.96,
          latencyMs: 82,
          receivedAt: 950,
        },
      ]),
    ).toThrow(RangeError);
  });
});
