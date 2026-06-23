// AssemblyAI v3 Universal Streaming server-message shapes and a narrowing parse.
//
// The current AssemblyAI streaming API is v3 (endpoint
// `wss://streaming.assemblyai.com/v3/ws`). It does NOT use the legacy v2
// `PartialTranscript` / `FinalTranscript` message types. Instead the server
// sends `Turn` messages carrying an `end_of_turn` flag: `false` is an interim
// (partial) result, `true` is the finalized turn. We model only the fields the
// provider consumes; unknown fields are ignored.

import { isRecord } from "../json";

// One recognized word inside a Turn. `start`/`end` are milliseconds from the
// session start (the `Begin` message). `confidence` is in [0, 1].
export interface AssemblyAiWord {
  readonly text: string;
  readonly start: number;
  readonly end: number;
  readonly confidence: number;
  readonly word_is_final: boolean;
}

// Sent once when the session opens. `expires_at` is a Unix timestamp (seconds).
export interface AssemblyAiBeginMessage {
  readonly type: "Begin";
  readonly id: string;
  readonly expires_at: number;
}

// The main transcript message, sent repeatedly. `end_of_turn === false` is a
// partial; `true` is the final turn. `transcript` is the text of finalized
// words so far. There is no transcript-level confidence in v3 — we aggregate
// `words[].confidence`.
export interface AssemblyAiTurnMessage {
  readonly type: "Turn";
  readonly turn_order: number;
  readonly end_of_turn: boolean;
  readonly turn_is_formatted: boolean;
  readonly transcript: string;
  readonly end_of_turn_confidence: number;
  readonly words: readonly AssemblyAiWord[];
}

// Sent after a graceful `Terminate`; confirms the session closed.
export interface AssemblyAiTerminationMessage {
  readonly type: "Termination";
  readonly audio_duration_seconds: number;
  readonly session_duration_seconds: number;
}

export type AssemblyAiServerMessage =
  | AssemblyAiBeginMessage
  | AssemblyAiTurnMessage
  | AssemblyAiTerminationMessage;

function parseWords(raw: unknown): AssemblyAiWord[] {
  if (!Array.isArray(raw)) return [];
  const words: AssemblyAiWord[] = [];
  for (const item of raw) {
    if (!isRecord(item)) continue;
    if (
      typeof item.text === "string" &&
      typeof item.start === "number" &&
      typeof item.end === "number" &&
      typeof item.confidence === "number" &&
      typeof item.word_is_final === "boolean"
    ) {
      words.push({
        text: item.text,
        start: item.start,
        end: item.end,
        confidence: item.confidence,
        word_is_final: item.word_is_final,
      });
    }
  }
  return words;
}

// Narrow an untrusted WebSocket payload (already JSON-parsed) into a typed v3
// server message. Returns `null` for unknown `type`s or malformed shapes so the
// stream can ignore messages it does not handle without throwing on the IPC
// boundary. Accepts a raw JSON string or an already-parsed object.
export function parseServerMessage(raw: unknown): AssemblyAiServerMessage | null {
  let value: unknown = raw;
  if (typeof raw === "string") {
    try {
      value = JSON.parse(raw);
    } catch {
      return null;
    }
  }
  if (!isRecord(value)) return null;

  switch (value.type) {
    case "Begin":
      if (typeof value.id === "string" && typeof value.expires_at === "number") {
        return { type: "Begin", id: value.id, expires_at: value.expires_at };
      }
      return null;
    case "Turn":
      if (
        typeof value.turn_order === "number" &&
        typeof value.end_of_turn === "boolean" &&
        typeof value.transcript === "string"
      ) {
        return {
          type: "Turn",
          turn_order: value.turn_order,
          end_of_turn: value.end_of_turn,
          turn_is_formatted:
            typeof value.turn_is_formatted === "boolean" ? value.turn_is_formatted : false,
          transcript: value.transcript,
          end_of_turn_confidence:
            typeof value.end_of_turn_confidence === "number" ? value.end_of_turn_confidence : 0,
          words: parseWords(value.words),
        };
      }
      return null;
    case "Termination":
      if (
        typeof value.audio_duration_seconds === "number" &&
        typeof value.session_duration_seconds === "number"
      ) {
        return {
          type: "Termination",
          audio_duration_seconds: value.audio_duration_seconds,
          session_duration_seconds: value.session_duration_seconds,
        };
      }
      return null;
    default:
      return null;
  }
}
