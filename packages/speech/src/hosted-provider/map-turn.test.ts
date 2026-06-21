import { describe, expect, it } from "vitest";

import { parseServerMessage } from "./assemblyai-messages";
import { mapTurn } from "./map-turn";
import type { AssemblyAiTurnMessage } from "./assemblyai-messages";

function turn(overrides: Partial<AssemblyAiTurnMessage> = {}): AssemblyAiTurnMessage {
  return {
    type: "Turn",
    turn_order: 0,
    end_of_turn: false,
    turn_is_formatted: false,
    transcript: "hello world",
    end_of_turn_confidence: 0.5,
    words: [
      { text: "hello", start: 0, end: 400, confidence: 0.9, word_is_final: true },
      { text: "world", start: 400, end: 800, confidence: 0.7, word_is_final: true },
    ],
    ...overrides,
  };
}

describe("mapTurn", () => {
  it("maps a non-final turn to a partial transcript", () => {
    const event = mapTurn(turn({ end_of_turn: false }), { sessionStartMs: 1000, now: 2000 });
    expect(event.kind).toBe("partial");
    expect(event.text).toBe("hello world");
  });

  it("maps an end-of-turn message to a final transcript", () => {
    const event = mapTurn(turn({ end_of_turn: true }), { sessionStartMs: 1000, now: 2000 });
    expect(event.kind).toBe("final");
    expect(event.text).toBe("hello world");
  });

  it("derives confidence from the mean of word confidences", () => {
    const event = mapTurn(turn(), { sessionStartMs: 0, now: 1000 });
    expect(event.confidence).toBeCloseTo(0.8, 5);
  });

  it("defaults confidence to 1 when the turn has no words", () => {
    const event = mapTurn(turn({ words: [] }), { sessionStartMs: 0, now: 1000 });
    expect(event.confidence).toBe(1);
  });

  it("computes latency as receive-time minus (sessionStart + last word end)", () => {
    // sessionStart=1000, last word ends at 800ms => audio end at epoch 1800.
    // now=2000 => latency 200ms.
    const event = mapTurn(turn(), { sessionStartMs: 1000, now: 2000 });
    expect(event.latencyMs).toBe(200);
  });

  it("never reports negative latency", () => {
    const event = mapTurn(turn(), { sessionStartMs: 5000, now: 1000 });
    expect(event.latencyMs).toBe(0);
  });

  it("does not throw and reports zero latency for an empty turn", () => {
    const event = mapTurn(turn({ words: [] }), { sessionStartMs: 1000, now: 1500 });
    expect(event.latencyMs).toBe(500);
    expect(event.receivedAt).toBe(1500);
  });

  it("reports zero latency when a Turn arrives before Begin (no session start)", () => {
    const event = mapTurn(turn(), { sessionStartMs: 0, now: 1_700_000_000_000 });
    expect(event.latencyMs).toBe(0);
  });
});

describe("parseServerMessage", () => {
  it("parses a valid Begin message", () => {
    const parsed = parseServerMessage({ type: "Begin", id: "abc", expires_at: 1700000000 });
    expect(parsed).toEqual({ type: "Begin", id: "abc", expires_at: 1700000000 });
  });

  it("parses a valid Turn message and its words", () => {
    const parsed = parseServerMessage({
      type: "Turn",
      turn_order: 2,
      end_of_turn: true,
      turn_is_formatted: true,
      transcript: "hi",
      end_of_turn_confidence: 0.95,
      words: [{ text: "hi", start: 0, end: 100, confidence: 0.99, word_is_final: true }],
    });
    expect(parsed?.type).toBe("Turn");
    if (parsed?.type === "Turn") {
      expect(parsed.words).toHaveLength(1);
      expect(parsed.words[0]?.text).toBe("hi");
    }
  });

  it("parses a valid Termination message", () => {
    const parsed = parseServerMessage({
      type: "Termination",
      audio_duration_seconds: 10,
      session_duration_seconds: 12,
    });
    expect(parsed?.type).toBe("Termination");
  });

  it("accepts a raw JSON string", () => {
    const parsed = parseServerMessage('{"type":"Begin","id":"x","expires_at":1}');
    expect(parsed?.type).toBe("Begin");
  });

  it("returns null for an unknown message type", () => {
    expect(parseServerMessage({ type: "SpeakerRevision", revisions: [] })).toBeNull();
  });

  it("returns null for malformed JSON", () => {
    expect(parseServerMessage("{not json")).toBeNull();
  });

  it("returns null for a Turn missing required fields", () => {
    expect(parseServerMessage({ type: "Turn", transcript: "hi" })).toBeNull();
  });

  it("drops malformed words but keeps a valid Turn", () => {
    const parsed = parseServerMessage({
      type: "Turn",
      turn_order: 0,
      end_of_turn: false,
      transcript: "hi",
      words: [
        { text: "hi" },
        { text: "ok", start: 0, end: 1, confidence: 0.5, word_is_final: true },
      ],
    });
    if (parsed?.type === "Turn") {
      expect(parsed.words).toHaveLength(1);
      expect(parsed.words[0]?.text).toBe("ok");
    } else {
      throw new Error("expected a Turn");
    }
  });
});
