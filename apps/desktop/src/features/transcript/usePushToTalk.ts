import type { FinalTranscript, SttError, SttStream, TranscriptWord } from "@handsoff/contracts";
import type { CaptureStatus } from "@handsoff/speech";
import { createCaptureController } from "@handsoff/speech";
import { useCallback, useEffect, useRef, useState } from "react";

// Drives the push-to-talk capture controller for the transcript UI (#32). The
// controller wraps an `SttStream` injected via `createStream`, so the panel runs
// against the real on-device / AssemblyAI provider in the app and against
// `FakeSttStream` in tests — the hook stays provider-agnostic.
//
// Capture is deliberate: nothing records until `press()`, each `release()`
// delivers exactly one stable final utterance, and `cancel()` discards an
// in-flight capture without finalizing. No always-listening, no wake word.

// A delivered final utterance, kept for display with its metadata.
export interface UtteranceEntry {
  readonly text: string;
  readonly confidence: number;
  readonly latencyMs: number;
  // The endpointed per-word epoch-ms timeline, when the provider exposed one.
  // Carried so the temporal binder can align deictic words with pointing
  // samples; absent on the on-device / no-words path.
  readonly words?: ReadonlyArray<TranscriptWord>;
}

export interface PushToTalkState {
  readonly status: CaptureStatus;
  // The live interim partial while capturing, cleared on endpoint (R2).
  readonly partial: string;
  // Stable final utterances in arrival order — one per capture (R3).
  readonly utterances: readonly UtteranceEntry[];
  // The last provider error, when status is "error" (R4).
  readonly error: SttError | null;
  press(): void;
  release(): void;
  cancel(): void;
}

export function usePushToTalk(
  createStream: () => SttStream,
  options: { onUtterance?: (utterance: FinalTranscript) => void } = {},
): PushToTalkState {
  const [status, setStatus] = useState<CaptureStatus>("idle");
  const [partial, setPartial] = useState("");
  const [utterances, setUtterances] = useState<readonly UtteranceEntry[]>([]);
  const [error, setError] = useState<SttError | null>(null);

  const mounted = useRef(true);

  // The controller is built once but must always open the *current* provider's
  // stream, so a Settings provider switch (a new `createStream`) takes effect on
  // the next capture. Route through a ref the render keeps fresh rather than
  // capturing the factory at build time.
  const createStreamRef = useRef(createStream);
  createStreamRef.current = createStream;
  const onUtteranceRef = useRef(options.onUtterance);
  onUtteranceRef.current = options.onUtterance;

  const controllerRef = useRef<ReturnType<typeof createCaptureController> | null>(null);
  if (controllerRef.current === null) {
    controllerRef.current = createCaptureController(() => createStreamRef.current(), {
      onUtterance: (utterance: FinalTranscript) => {
        if (!mounted.current) return;
        setUtterances((prev) => [...prev, toEntry(utterance)]);
        setPartial("");
        onUtteranceRef.current?.(utterance);
      },
      onPartial: (text) => {
        if (mounted.current) setPartial(text);
      },
      onStatus: (next) => {
        if (mounted.current) setStatus(next);
      },
      onError: (sttError) => {
        if (mounted.current) setError(sttError);
      },
    });
  }

  useEffect(() => {
    mounted.current = true;
    return () => {
      mounted.current = false;
      // Release the mic + socket if the panel unmounts mid-capture.
      void controllerRef.current?.cancel();
    };
  }, []);

  const press = useCallback(() => {
    setError(null);
    setPartial("");
    void controllerRef.current?.press();
  }, []);

  const release = useCallback(() => {
    void controllerRef.current?.release();
  }, []);

  const cancel = useCallback(() => {
    setPartial("");
    void controllerRef.current?.cancel();
  }, []);

  return { status, partial, utterances, error, press, release, cancel };
}

function toEntry(utterance: FinalTranscript): UtteranceEntry {
  return {
    text: utterance.text,
    confidence: utterance.confidence,
    latencyMs: utterance.latencyMs,
    ...(utterance.words ? { words: utterance.words } : {}),
  };
}
