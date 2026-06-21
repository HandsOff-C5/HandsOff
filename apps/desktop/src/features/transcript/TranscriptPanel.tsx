import type { SttError, SttErrorKind, SttStream } from "@handsoff/contracts";

import { useSttStream } from "./useSttStream";

// Live transcript surface (#31): shows the interim partial while speaking, the
// finalized transcripts with confidence + latency, and a visible, recoverable
// error state. The stream is injected via `createStream` so this panel runs
// against the real AssemblyAI provider in the app and `FakeSttStream` in tests.
//
// When `createStream` is absent (no Tauri backend), the panel shows an
// unavailable state — the dashboard never blanks. Issue #32 replaces the manual
// Start/Stop control with push-to-talk.

interface TranscriptPanelProps {
  // Builds a fresh stream per start. Omitted when no native backend is present.
  createStream?: () => SttStream;
}

const ERROR_COPY: Record<SttErrorKind, string> = {
  "mic-permission": "Microphone access denied. Grant it in System Settings → Privacy & Security.",
  "start-failed": "Could not start the microphone.",
  network: "The connection dropped. Retry to continue.",
  "provider-unavailable": "The speech service is unavailable. Retry to continue.",
  aborted: "Listening was cancelled.",
};

function errorMessage(error: SttError): string {
  return ERROR_COPY[error.kind] ?? error.message;
}

export function TranscriptPanel({ createStream }: TranscriptPanelProps) {
  if (!createStream) {
    return (
      <section className="panel transcript">
        <h2 className="panel__title">Transcript</h2>
        <p className="transcript__unavailable">Mac app required for live speech.</p>
      </section>
    );
  }
  return <LiveTranscriptPanel createStream={createStream} />;
}

function LiveTranscriptPanel({ createStream }: { createStream: () => SttStream }) {
  const { status, partial, finals, error, start, stop } = useSttStream(createStream);
  const listening = status === "listening";

  return (
    <section className="panel transcript">
      <div className="transcript__header">
        <h2 className="panel__title">Transcript</h2>
        <button className="transcript__toggle" type="button" onClick={listening ? stop : start}>
          {listening ? "Stop" : "Speak"}
        </button>
      </div>

      {error ? (
        <div className="transcript__error" role="alert">
          <span>{errorMessage(error)}</span>
          <button className="transcript__retry" type="button" onClick={start}>
            Retry
          </button>
        </div>
      ) : null}

      <p className="transcript__partial" aria-live="polite" data-testid="transcript-partial">
        {partial}
      </p>

      <ul className="transcript__finals">
        {finals.map((entry, index) => (
          <li key={index} className="transcript__final">
            <span className="transcript__final-text">{entry.text}</span>
            <span className="transcript__final-meta">
              {Math.round(entry.confidence * 100)}% · {Math.round(entry.latencyMs)} ms
            </span>
          </li>
        ))}
      </ul>
    </section>
  );
}
