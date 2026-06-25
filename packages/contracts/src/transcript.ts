import { z } from "zod";

import type { PermissionState } from "./readiness";

// The streaming speech-to-text provider contract (issue #30, AD2).
//
// Two concepts share the "STT provider" name and must not collide:
//   - `SttProvider` in `config.ts` is the *selection id* — which provider the
//     user configured (today: "assemblyai"). It is a string enum mirrored by
//     the Rust `SttProvider` enum.
//   - `SttStream` (below) is the *runtime contract* — the behavioral interface
//     an active provider session satisfies. It is what the orchestration layer
//     starts and stops, and what emits transcript events to the intent engine.
//
// Keeping the stream behind a provider-agnostic interface lets us swap the
// hosted AssemblyAI realtime provider (AD2) for a local or alternate provider
// without rewriting transcript UI or intent parsing — the cross-area boundary
// carries only `TranscriptEvent`s and typed lifecycle errors. Per #30's scope
// boundary, this file defines the interface and types only; no real provider is
// implemented here.

// Confidence a provider attaches to a transcript, in [0, 1]. 1 = certain.
export type SttConfidence = number;

// End-to-end latency for a transcript event, in milliseconds, measured from the
// audio chunk that produced it to the event being emitted. Budgeted at
// ~300 ms P50 for the hosted provider (AD2).
export type SttLatencyMs = number;

// Epoch timestamp (ms) at which the event was emitted by the provider.
export type SttReceivedAtMs = number;

// One recognized word with its place on the wall clock. `startMs`/`endMs` are
// EPOCH milliseconds (not relative to session start) so a downstream binder can
// align a spoken word with head/hand pointing samples that are also epoch-ms.
// `confidence` is in [0, 1]. A provider that does not expose per-word timing
// (e.g. the on-device path) simply omits the parent `words` array.
export interface TranscriptWord {
  readonly text: string;
  readonly startMs: number;
  readonly endMs: number;
  readonly confidence: SttConfidence;
}

const transcriptWordSchema = z.object({
  text: z.string().min(1),
  startMs: z.number().nonnegative(),
  endMs: z.number().nonnegative(),
  confidence: z.number().min(0).max(1),
});

// Interim transcript — still being revised. A later partial or the final may
// replace its text. Intent parsing must not commit on a partial alone.
export interface PartialTranscript {
  readonly kind: "partial";
  readonly text: string;
  readonly confidence: SttConfidence;
  readonly latencyMs: SttLatencyMs;
  readonly receivedAt: SttReceivedAtMs;
  // Per-word epoch-ms timeline for this turn, when the provider exposes it.
  // Carried on partials too so endpointing can fold the timeline across the
  // revisions of one utterance.
  readonly words?: ReadonlyArray<TranscriptWord>;
}

const transcriptBaseSchema = z.object({
  text: z.string().min(1),
  confidence: z.number().min(0).max(1),
  latencyMs: z.number().nonnegative(),
  receivedAt: z.number().nonnegative(),
  // `.readonly()` so the inferred type matches the hand-written `readonly`
  // `words` on `PartialTranscript`/`FinalTranscript` and on `IntentInput`.
  words: z.array(transcriptWordSchema).readonly().optional(),
});

export const partialTranscriptSchema = transcriptBaseSchema.extend({
  kind: z.literal("partial"),
});

// Final transcript — stable; will not be revised. This is what the intent
// engine fuses with the referent candidate.
export interface FinalTranscript {
  readonly kind: "final";
  readonly text: string;
  readonly confidence: SttConfidence;
  readonly latencyMs: SttLatencyMs;
  readonly receivedAt: SttReceivedAtMs;
  // The endpointed per-word epoch-ms timeline spanning the whole utterance, when
  // the provider exposes word timing. Omitted on the on-device / no-words path.
  readonly words?: ReadonlyArray<TranscriptWord>;
}

export const finalTranscriptSchema = transcriptBaseSchema.extend({
  kind: z.literal("final"),
});

export type TranscriptEvent = PartialTranscript | FinalTranscript;

export const transcriptEventSchema = z.discriminatedUnion("kind", [
  partialTranscriptSchema,
  finalTranscriptSchema,
]);

// Typed provider lifecycle error kinds. Surfaced as `SttErrorEvent` on the
// stream listener for mid-stream failures, or carried by `SttLifecycleError`
// when `start()` rejects. Never thrown as a raw `Error` across the area
// boundary — the orchestration layer decides how to present them.
export const STT_ERROR_KINDS = [
  // Microphone permission was denied or revoked.
  "mic-permission",
  // The provider could not start capture (device busy, misconfigured, etc.).
  "start-failed",
  // A network failure interrupted the stream after it had started.
  "network",
  // The provider service rejected or dropped the session.
  "provider-unavailable",
  // stop() was called while a start was still pending — no transcripts emitted.
  "aborted",
] as const;

export type SttErrorKind = (typeof STT_ERROR_KINDS)[number];

export interface SttError {
  readonly kind: SttErrorKind;
  readonly message: string;
  // For mic-permission errors, the specific permission state that caused the error.
  // The UI uses this to distinguish between "not requested yet" and "blocked" without
  // parsing error messages.
  readonly permissionState?: PermissionState;
  // Underlying cause for diagnostics; not surfaced to the user.
  readonly cause?: unknown;
}

export interface SttErrorEvent {
  readonly kind: "error";
  readonly error: SttError;
  readonly receivedAt: SttReceivedAtMs;
}

export type SttStreamEvent = TranscriptEvent | SttErrorEvent;

export type SttStreamListener = (event: SttStreamEvent) => void;

// A typed lifecycle error. `start()` rejects with this when the stream cannot
// be opened, so callers can narrow on `sttError.kind` rather than parsing
// messages. Mid-stream failures arrive as `SttErrorEvent` on the listener
// instead.
export class SttLifecycleError extends Error {
  readonly sttError: SttError;

  constructor(sttError: SttError) {
    super(sttError.message);
    this.name = "SttLifecycleError";
    this.sttError = sttError;
  }
}

// The provider-agnostic streaming STT contract (AD2).
//
// Lifecycle:
//   1. `start(listener)` begins capture and resolves once the stream is open.
//      A failure to open rejects with an `SttLifecycleError` whose `sttError`
//      kind is "start-failed" or "mic-permission".
//   2. While open, the listener receives `PartialTranscript`,
//      `FinalTranscript`, and `SttErrorEvent` events. A mid-stream error does
//      not auto-close the stream; the caller decides whether to `stop()`.
//   3. `stop()` ends capture and resolves once teardown is complete. After it
//      resolves, no further events fire on the listener.
//
// Re-entrancy: calling `start()` on an already-open stream rejects with an
// `SttLifecycleError` of kind "start-failed". Calling `stop()` on an
// already-stopped stream resolves without effect (idempotent).
export interface SttStream {
  start(listener: SttStreamListener): Promise<void>;
  stop(): Promise<void>;
}
