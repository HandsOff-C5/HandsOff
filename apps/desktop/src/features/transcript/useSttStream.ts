import type { FinalTranscript, SttError, SttStream, SttStreamEvent } from "@handsoff/contracts";
import { SttLifecycleError } from "@handsoff/contracts";
import { useCallback, useEffect, useRef, useState } from "react";

// Drives an `SttStream` for the transcript UI (#31). The stream is injected via
// a `createStream` factory so the panel can run against the real AssemblyAI
// provider in the app and against `FakeSttStream` in tests — the hook itself
// has no knowledge of which provider it speaks to.
//
// A fresh stream is created per `start()` so retry-after-error works without
// reusing a stopped session.

export type SttStatus = "idle" | "listening" | "error" | "stopped";

// A delivered final transcript, kept for display with its metadata (R3).
export interface FinalEntry {
  readonly text: string;
  readonly confidence: number;
  readonly latencyMs: number;
}

export interface SttStreamState {
  readonly status: SttStatus;
  // The current interim transcript text, replaced as partials arrive (R2).
  readonly partial: string;
  // Finalized transcripts in arrival order (R3).
  readonly finals: readonly FinalEntry[];
  // The last provider error, when status is "error" (R4).
  readonly error: SttError | null;
  start(): void;
  stop(): void;
}

export function useSttStream(createStream: () => SttStream): SttStreamState {
  const [status, setStatus] = useState<SttStatus>("idle");
  const [partial, setPartial] = useState("");
  const [finals, setFinals] = useState<readonly FinalEntry[]>([]);
  const [error, setError] = useState<SttError | null>(null);

  const streamRef = useRef<SttStream | null>(null);
  const mounted = useRef(true);

  useEffect(() => {
    mounted.current = true;
    return () => {
      mounted.current = false;
      // Release the mic + socket if the panel unmounts mid-session.
      void streamRef.current?.stop();
      streamRef.current = null;
    };
  }, []);

  const onEvent = useCallback((event: SttStreamEvent) => {
    if (!mounted.current) return;
    switch (event.kind) {
      case "partial":
        setPartial(event.text);
        setStatus("listening");
        break;
      case "final":
        setFinals((prev) => [...prev, toFinalEntry(event)]);
        setPartial("");
        setStatus("listening");
        break;
      case "error":
        setError(event.error);
        setStatus("error");
        break;
    }
  }, []);

  const start = useCallback(() => {
    setError(null);
    setPartial("");
    // Release any prior session before opening a new one. A mid-stream error
    // does not auto-close the stream (per contract), so a retry must stop the
    // old mic + socket — otherwise two streams feed this same listener.
    void streamRef.current?.stop();
    const stream = createStream();
    streamRef.current = stream;
    setStatus("listening");
    void stream.start(onEvent).catch((caught: unknown) => {
      if (!mounted.current) return;
      // An `aborted` rejection means stop() raced an in-flight start — that's a
      // user-initiated stop, not a failure to surface.
      const error = toSttError(caught);
      if (error.kind === "aborted") return;
      streamRef.current = null;
      setError(error);
      setStatus("error");
    });
  }, [createStream, onEvent]);

  const stop = useCallback(() => {
    const stream = streamRef.current;
    streamRef.current = null;
    setStatus("stopped");
    setPartial("");
    void stream?.stop();
  }, []);

  return { status, partial, finals, error, start, stop };
}

function toFinalEntry(event: FinalTranscript): FinalEntry {
  return { text: event.text, confidence: event.confidence, latencyMs: event.latencyMs };
}

function toSttError(caught: unknown): SttError {
  if (caught instanceof SttLifecycleError) return caught.sttError;
  return {
    kind: "start-failed",
    message: caught instanceof Error ? caught.message : "Could not start listening",
    cause: caught,
  };
}
