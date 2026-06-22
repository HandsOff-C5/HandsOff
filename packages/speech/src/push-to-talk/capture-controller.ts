import type { FinalTranscript, SttError, SttStream, SttStreamEvent } from "@handsoff/contracts";
import { SttLifecycleError } from "@handsoff/contracts";

import {
  EMPTY_UTTERANCE,
  endpointUtterance,
  foldUtterance,
  type UtteranceState,
} from "../endpointing";

// Push-to-talk capture state machine (#32, AD2).
//
// Wraps any `SttStream` provider with deliberate-activation capture: nothing is
// recorded until the user explicitly arms it, and each capture delivers exactly
// one stable final utterance to the intent engine — never an always-listening
// background stream (the issue's scope boundary).
//
// Lifecycle (the only legal transitions):
//   idle → press() → capturing
//   capturing → release() → idle, emitting one utterance (endpointing)
//   capturing → cancel()  → idle, discarding (no utterance)
//   capturing → provider error → error
//   error → press() → capturing (fresh stream)
//
// `press`/`release`/`cancel` are the trigger-agnostic verbs: a push-to-talk key,
// a hold-to-talk button, or a gesture-plus-voice arm all map onto the same three
// calls. They return promises so callers (and tests) can await the stream's
// open/close, but UI handlers may fire-and-forget them.

export type CaptureStatus = "idle" | "capturing" | "finalizing" | "error";

export interface CaptureControllerCallbacks {
  // The single stable final utterance for a capture that endpointed with speech.
  // Not called on cancel, on an empty capture, or on error.
  readonly onUtterance: (utterance: FinalTranscript) => void;
  // The live interim partial, for "what I'm hearing" UI while capturing.
  readonly onPartial?: (text: string) => void;
  // Status transitions, for driving UI affordances.
  readonly onStatus?: (status: CaptureStatus) => void;
  // A provider/lifecycle error that ended the capture.
  readonly onError?: (error: SttError) => void;
  // Injectable clock (epoch ms) for deterministic endpoint timestamps.
  readonly now?: () => number;
}

export interface CaptureController {
  // Arm capture (push-to-talk press / gesture-plus-voice). No-op while already
  // capturing or finalizing.
  press(): Promise<void>;
  // Endpoint: stop capture and deliver the one stable final utterance.
  release(): Promise<void>;
  // Abort capture before finalizing — release the mic, emit nothing.
  cancel(): Promise<void>;
  readonly status: CaptureStatus;
}

export function createCaptureController(
  createStream: () => SttStream,
  callbacks: CaptureControllerCallbacks,
): CaptureController {
  const now = callbacks.now ?? (() => Date.now());

  let status: CaptureStatus = "idle";
  let stream: SttStream | null = null;
  let utterance: UtteranceState = EMPTY_UTTERANCE;
  // Bumped to fence off a superseded session's late events (on cancel/error) so
  // a stale partial can never bleed into the next capture.
  let generation = 0;

  function setStatus(next: CaptureStatus): void {
    status = next;
    callbacks.onStatus?.(next);
  }

  function handleEvent(generationAtStart: number, event: SttStreamEvent): void {
    if (generationAtStart !== generation) return;
    switch (event.kind) {
      case "partial":
        utterance = foldUtterance(utterance, event);
        callbacks.onPartial?.(event.text);
        break;
      case "final":
        utterance = foldUtterance(utterance, event);
        break;
      case "error":
        void fail(event.error);
        break;
    }
  }

  // Release the active stream; resolves once teardown is complete, after which
  // the contract guarantees no further events fire.
  async function teardown(): Promise<void> {
    const active = stream;
    stream = null;
    await active?.stop();
  }

  async function fail(error: SttError): Promise<void> {
    generation += 1;
    await teardown();
    utterance = EMPTY_UTTERANCE;
    setStatus("error");
    callbacks.onError?.(error);
  }

  return {
    get status(): CaptureStatus {
      return status;
    },

    async press(): Promise<void> {
      if (status === "capturing" || status === "finalizing") return;
      const generationAtStart = (generation += 1);
      utterance = EMPTY_UTTERANCE;
      setStatus("capturing");

      const next = createStream();
      stream = next;
      try {
        await next.start((event) => handleEvent(generationAtStart, event));
      } catch (caught) {
        // A release()/cancel() may have superseded this start while it was in
        // flight (cancel bumps the generation; release nulls the stream in
        // teardown). Either way, let that transition stand.
        if (generationAtStart !== generation || stream !== next) return;
        const error = toSttError(caught);
        // `aborted` means stop() raced this start — a user-initiated stop, not a
        // failure to surface.
        if (error.kind === "aborted") return;
        stream = null;
        setStatus("error");
        callbacks.onError?.(error);
      }
    },

    async release(): Promise<void> {
      if (status !== "capturing") return;
      setStatus("finalizing");
      // Keep the same generation through teardown so a final that lands as the
      // stream drains is still folded into this utterance.
      await teardown();
      const result = endpointUtterance(utterance, {
        receivedAt: now(),
        includeTrailingPartial: true,
      });
      utterance = EMPTY_UTTERANCE;
      setStatus("idle");
      if (result) callbacks.onUtterance(result);
    },

    async cancel(): Promise<void> {
      if (status !== "capturing") return;
      // Fence off any in-flight events — this capture is discarded.
      generation += 1;
      setStatus("finalizing");
      await teardown();
      utterance = EMPTY_UTTERANCE;
      setStatus("idle");
    },
  };
}

function toSttError(caught: unknown): SttError {
  if (caught instanceof SttLifecycleError) return caught.sttError;
  return {
    kind: "start-failed",
    message: caught instanceof Error ? caught.message : "Could not start listening",
    cause: caught,
  };
}
