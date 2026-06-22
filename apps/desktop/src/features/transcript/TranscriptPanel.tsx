import type { SttError, SttErrorKind, SttStream } from "@handsoff/contracts";

import { usePushToTalk } from "./usePushToTalk";

// Live transcript surface (#31, #32): push-to-talk capture that shows the
// interim partial while the user holds to speak, then renders the one stable
// final utterance the capture produced (endpointing). The stream is injected via
// `createStream` so this panel runs against the real on-device / AssemblyAI
// provider in the app and `FakeSttStream` in tests.
//
// Capture is deliberate (the issue's scope boundary: no wake word, no
// always-listening): hold the button to capture, release to send, slide off or
// hit Escape to cancel before it finalizes. When `createStream` is absent (no
// Tauri backend) the panel shows an unavailable state — the dashboard never
// blanks.

interface TranscriptPanelProps {
  // Builds a fresh stream per capture. Omitted when no native backend is present.
  createStream?: () => SttStream;
}

const ERROR_COPY: Record<SttErrorKind, string> = {
  "mic-permission": "Microphone access denied. Grant it in System Settings → Privacy & Security.",
  "start-failed": "Could not start the microphone.",
  network: "The connection dropped. Hold to talk again to retry.",
  "provider-unavailable": "The speech service is unavailable. Hold to talk again to retry.",
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
  const { status, partial, utterances, error, press, release, cancel } =
    usePushToTalk(createStream);
  const capturing = status === "capturing" || status === "finalizing";

  return (
    <section className="panel transcript">
      <div className="transcript__header">
        <h2 className="panel__title">Transcript</h2>
        <button
          className="transcript__talk"
          type="button"
          aria-pressed={capturing}
          onPointerDown={press}
          onPointerUp={release}
          // Sliding the pointer off a held button aborts before finalizing.
          onPointerLeave={capturing ? cancel : undefined}
          onPointerCancel={cancel}
          onKeyDown={(event) => {
            if (capturing && event.key === "Escape") cancel();
          }}
        >
          {capturing ? "Release to send" : "Hold to talk"}
        </button>
      </div>

      {capturing ? (
        <button className="transcript__cancel" type="button" onClick={cancel}>
          Cancel
        </button>
      ) : null}

      {error ? (
        <div className="transcript__error" role="alert">
          {errorMessage(error)}
        </div>
      ) : null}

      <p className="transcript__partial" aria-live="polite" data-testid="transcript-partial">
        {partial}
      </p>

      <ul className="transcript__finals">
        {utterances.map((entry, index) => (
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
