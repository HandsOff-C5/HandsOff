import { describe, expect, it } from "vitest";

import {
  finalTranscriptSchema,
  partialTranscriptSchema,
  transcriptEventSchema,
} from "./transcript";

const word = { text: "this", startMs: 1000, endMs: 1300, confidence: 0.9 };

describe("transcript word timeline (U4)", () => {
  it("accepts a final transcript carrying a per-word epoch-ms timeline", () => {
    const parsed = finalTranscriptSchema.parse({
      kind: "final",
      text: "type this",
      confidence: 0.9,
      latencyMs: 100,
      receivedAt: 1_700_000_000_000,
      words: [word],
    });
    expect(parsed.words).toHaveLength(1);
    expect(parsed.words?.[0]?.startMs).toBe(1000);
  });

  it("accepts a final transcript with `words` omitted (no-words path)", () => {
    const parsed = finalTranscriptSchema.parse({
      kind: "final",
      text: "type this",
      confidence: 0.9,
      latencyMs: 100,
      receivedAt: 1_700_000_000_000,
    });
    expect(parsed.words).toBeUndefined();
  });

  it("accepts words on a partial transcript", () => {
    const parsed = partialTranscriptSchema.parse({
      kind: "partial",
      text: "this",
      confidence: 0.5,
      latencyMs: 0,
      receivedAt: 1,
      words: [word],
    });
    expect(parsed.words?.[0]?.text).toBe("this");
  });

  it("rejects a word with out-of-range confidence", () => {
    expect(() =>
      finalTranscriptSchema.parse({
        kind: "final",
        text: "type this",
        confidence: 0.9,
        latencyMs: 0,
        receivedAt: 1,
        words: [{ ...word, confidence: 2 }],
      }),
    ).toThrow();
  });

  it("rejects a word with a negative timestamp", () => {
    expect(() =>
      finalTranscriptSchema.parse({
        kind: "final",
        text: "type this",
        confidence: 0.9,
        latencyMs: 0,
        receivedAt: 1,
        words: [{ ...word, startMs: -1 }],
      }),
    ).toThrow();
  });

  it("rejects an empty word text", () => {
    expect(() =>
      finalTranscriptSchema.parse({
        kind: "final",
        text: "type this",
        confidence: 0.9,
        latencyMs: 0,
        receivedAt: 1,
        words: [{ ...word, text: "" }],
      }),
    ).toThrow();
  });

  it("carries words through the discriminated transcript-event union", () => {
    const parsed = transcriptEventSchema.parse({
      kind: "final",
      text: "this",
      confidence: 1,
      latencyMs: 0,
      receivedAt: 1,
      words: [word],
    });
    expect(parsed.kind).toBe("final");
    if (parsed.kind === "final") expect(parsed.words).toHaveLength(1);
  });
});
