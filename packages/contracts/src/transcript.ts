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

// Interim transcript — still being revised. A later partial or the final may
// replace its text. Intent parsing must not commit on a partial alone.
export interface PartialTranscript {
  readonly kind: "partial";
  readonly text: string;
  readonly confidence: SttConfidence;
  readonly latencyMs: SttLatencyMs;
  readonly receivedAt: SttReceivedAtMs;
}

// Final transcript — stable; will not be revised. This is what the intent
// engine fuses with the referent candidate.
export interface FinalTranscript {
  readonly kind: "final";
  readonly text: string;
  readonly confidence: SttConfidence;
  readonly latencyMs: SttLatencyMs;
  readonly receivedAt: SttReceivedAtMs;
}

export type TranscriptEvent = PartialTranscript | FinalTranscript;

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
    if (sttError.cause !== undefined) {
      (this as { cause?: unknown }).cause = sttError.cause;
    }
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
