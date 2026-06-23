import type { FinalTranscript, SttError, SttErrorKind, SttStream } from "@handsoff/contracts";
import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";

import { useCaptureHotkey } from "../head-pointing/useCaptureHotkey";
import { usePushToTalk } from "./usePushToTalk";

function hasTauriBackend(): boolean {
  return typeof window !== "undefined" && "__TAURI_INTERNALS__" in window;
}

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
  onFinalTranscript?: (utterance: FinalTranscript) => void;
}

const ERROR_COPY: Record<SttErrorKind, string> = {
  "mic-permission": "Microphone access denied. Grant it in System Settings → Privacy & Security.",
  "start-failed": "Could not start the microphone.",
  network: "The connection dropped. Hold to talk again to retry.",
  "provider-unavailable": "The speech service is unavailable. Hold to talk again to retry.",
  aborted: "Listening was cancelled.",
};

function errorMessage(error: SttError): string {
  if (error.kind === "start-failed" && error.message) return error.message;
  if (error.kind === "mic-permission") {
    // Use typed permission state when available, otherwise fall back to message parsing.
    if (error.permissionState === "not-determined") {
      return "Speech recognition has not been requested yet. Choose Allow microphone & speech in Permissions, then hold to talk again.";
    }
    if (error.permissionState === "denied" || error.permissionState === "restricted") {
      return "Speech recognition is blocked. Enable it in System Settings → Privacy & Security → Speech Recognition.";
    }
    // Fallback for legacy errors without permissionState.
    if (/speech recognition/i.test(error.message)) {
      if (/\(0\)|not.*determined/i.test(error.message)) {
        return "Speech recognition has not been requested yet. Choose Allow microphone & speech in Permissions, then hold to talk again.";
      }
      return "Speech recognition is blocked. Enable it in System Settings → Privacy & Security → Speech Recognition.";
    }
  }
  return ERROR_COPY[error.kind] ?? error.message;
}

export function TranscriptPanel({ createStream, onFinalTranscript }: TranscriptPanelProps) {
  if (!createStream) {
    return (
      <section className="panel transcript">
        <h2 className="panel__title">Transcript</h2>
        <p className="transcript__unavailable">Mac app required for live speech.</p>
      </section>
    );
  }
  return <LiveTranscriptPanel createStream={createStream} onFinalTranscript={onFinalTranscript} />;
}

function LiveTranscriptPanel({
  createStream,
  onFinalTranscript,
}: {
  createStream: () => SttStream;
  onFinalTranscript?: (utterance: FinalTranscript) => void;
}) {
  const { status, partial, utterances, error, press, release, cancel } = usePushToTalk(
    createStream,
    { onUtterance: onFinalTranscript },
  );
  const capturing = status === "capturing" || status === "finalizing";
  const tauri = hasTauriBackend();

  // Drive mic capture from the Option + ? hotkey (#95): hold = press, release.
  useCaptureHotkey(
    tauri
      ? {
          listen: (event, handler) => listen(event, ({ payload }) => handler({ payload })),
          invoke: (command) => invoke(command),
          onStart: press,
          onStop: release,
        }
      : undefined,
  );

  // Full-capture test (#95): a button that fires the SAME downstream path as the
  // hotkey — head tracking (golden cursor + camera) plus mic — so the core loop
  // can be exercised independently of the global-shortcut press. Request camera
  // (+ mic/speech) first so the head-track sidecar, spawned as a child of the app,
  // inherits a real camera grant — without it the golden overlay never appears.
  const startCapture = () => {
    if (tauri) {
      void invoke("request_media_permissions").finally(() => {
        void invoke("head_track_start");
      });
    }
    press();
  };
  const stopCapture = () => {
    release();
    if (tauri) void invoke("head_track_stop");
  };
  const cancelCapture = () => {
    cancel();
    if (tauri) void invoke("head_track_stop");
  };

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

      {/* Test the full capture path (head tracking + mic) without the hotkey (#95). */}
      {tauri && (
        <button
          className="transcript__capture-test"
          type="button"
          aria-pressed={capturing}
          onPointerDown={startCapture}
          onPointerUp={stopCapture}
          onPointerLeave={capturing ? cancelCapture : undefined}
          onPointerCancel={cancelCapture}
        >
          {capturing ? "Release (head + voice)" : "Hold to capture (head + voice)"}
        </button>
      )}

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
