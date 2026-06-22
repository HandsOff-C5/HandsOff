import type { SttError, SttStream, SttStreamListener } from "@handsoff/contracts";
import { SttLifecycleError } from "@handsoff/contracts";

import { parseServerMessage } from "./assemblyai-messages";
import { mapTurn } from "./map-turn";
import { startMicCapture, type MicCaptureHandle } from "./mic-capture";

// AssemblyAI v3 Universal Streaming provider implementing the `SttStream`
// contract (#31, AD2).
//
// `start()` mints a short-lived token (via the injected `tokenProvider` — the
// app supplies one backed by a Tauri command so the API key never reaches the
// webview), opens the mic, connects the v3 WebSocket, and streams 16 kHz binary
// PCM frames. Inbound `Turn` messages are mapped to `TranscriptEvent`s (partial
// vs final by `end_of_turn`) and delivered to the listener. `stop()` sends a
// graceful `Terminate` and releases the mic + socket.
//
// This adapter is real network + microphone I/O; it is verified by the live
// demo and by the transcript-UI integration tests (which run against
// `FakeSttStream`, not a mocked socket). The pure pieces it composes — the Turn
// mapper and the resampler — are unit-tested in isolation.

const V3_ENDPOINT = "wss://streaming.assemblyai.com/v3/ws";
const SAMPLE_RATE = 16000;

// Provides a fresh single-use streaming token. The desktop app implements this
// by invoking the Rust `stt_mint_token` command; tests/other hosts can supply
// any async source.
export type TokenProvider = () => Promise<string>;

export interface AssemblyAiStreamOptions {
  readonly tokenProvider: TokenProvider;
  // Override the WebSocket constructor (testing / non-browser hosts). Defaults
  // to the global `WebSocket`.
  readonly webSocketFactory?: (url: string) => WebSocket;
  readonly micFactory?: typeof startMicCapture;
}

type State = "idle" | "starting" | "open" | "stopped";

function buildConnectUrl(token: string): string {
  const params = new URLSearchParams({
    speech_model: "u3-rt-pro",
    sample_rate: String(SAMPLE_RATE),
    encoding: "pcm_s16le",
    format_turns: "true",
    token,
  });
  return `${V3_ENDPOINT}?${params.toString()}`;
}

export function createAssemblyAiStream(options: AssemblyAiStreamOptions): SttStream {
  const makeSocket = options.webSocketFactory ?? ((url: string) => new WebSocket(url));
  const openMic = options.micFactory ?? startMicCapture;

  let state: State = "idle";
  let socket: WebSocket | null = null;
  let mic: MicCaptureHandle | null = null;
  let listener: SttStreamListener | null = null;
  let sessionStartMs = 0;
  // Set when stop() is called while a start() is still in flight, so the
  // pending start tears itself down at the next checkpoint instead of
  // resurrecting a session the caller already abandoned.
  let stopRequested = false;

  async function teardown(): Promise<void> {
    if (mic) {
      await mic.stop();
      mic = null;
    }
    if (socket) {
      try {
        if (socket.readyState === WebSocket.OPEN) {
          socket.send(JSON.stringify({ type: "Terminate" }));
        }
        socket.close();
      } catch {
        // Socket already closing/closed.
      }
      socket = null;
    }
  }

  // Release everything, clear the listener, and mark the stream stopped, then
  // reject the in-flight start() with `error`. Used on every start failure so
  // no path leaves the mic or socket live.
  async function failStart(error: unknown): Promise<never> {
    await teardown();
    listener = null;
    state = "stopped";
    throw error;
  }

  // Bail out of a pending start() if stop() was called while awaiting. Emits no
  // transcripts (contract `aborted` semantics).
  async function throwIfStopped(): Promise<void> {
    if (stopRequested) {
      await failStart(
        new SttLifecycleError({
          kind: "aborted",
          message: "Listening was stopped before the stream opened",
        }),
      );
    }
  }

  function emitError(error: SttError): void {
    listener?.({ kind: "error", error, receivedAt: Date.now() });
  }

  function handleMessage(data: unknown): void {
    const message = parseServerMessage(data);
    if (!message) return;
    if (message.type === "Begin") {
      sessionStartMs = Date.now();
      return;
    }
    if (message.type === "Turn") {
      listener?.(mapTurn(message, { sessionStartMs, now: Date.now() }));
    }
    // Termination is handled by the close handler / stop().
  }

  return {
    async start(nextListener: SttStreamListener): Promise<void> {
      if (state === "open" || state === "starting") {
        throw new SttLifecycleError({
          kind: "start-failed",
          message: "start() called on an already-active AssemblyAI stream",
        });
      }
      state = "starting";
      stopRequested = false;
      listener = nextListener;

      let token: string;
      try {
        token = await options.tokenProvider();
      } catch (error) {
        return failStart(
          new SttLifecycleError({
            kind: "provider-unavailable",
            message: "Could not obtain a streaming token",
            cause: error,
          }),
        );
      }
      await throwIfStopped();

      // Open the WebSocket and wait for it to connect (or fail) before
      // starting the mic, so a connect failure surfaces as a start rejection.
      const ws = makeSocket(buildConnectUrl(token));
      ws.binaryType = "arraybuffer";
      socket = ws;

      try {
        await new Promise<void>((resolve, reject) => {
          const onOpen = () => {
            ws.removeEventListener("error", onError);
            resolve();
          };
          const onError = () => {
            ws.removeEventListener("open", onOpen);
            reject(
              new SttLifecycleError({
                kind: "provider-unavailable",
                message: "Could not connect to the AssemblyAI streaming service",
              }),
            );
          };
          ws.addEventListener("open", onOpen, { once: true });
          ws.addEventListener("error", onError, { once: true });
        });
      } catch (error) {
        return failStart(error);
      }
      await throwIfStopped();

      ws.addEventListener("message", (event: MessageEvent) => handleMessage(event.data));
      ws.addEventListener("error", () =>
        emitError({ kind: "network", message: "The streaming connection errored" }),
      );
      ws.addEventListener("close", (event: CloseEvent) => {
        // A clean close after Terminate is expected; an unexpected close while
        // open is a recoverable provider failure.
        if (state === "open" && !event.wasClean) {
          emitError({
            kind: "provider-unavailable",
            message: "The streaming session closed unexpectedly",
          });
        }
      });

      try {
        mic = await openMic({
          onFrame: (frame) => {
            if (ws.readyState === WebSocket.OPEN) ws.send(frame.buffer as ArrayBuffer);
          },
        });
      } catch (error) {
        return failStart(error);
      }
      await throwIfStopped();

      // The socket may have closed during mic initialization (e.g. a rejected
      // token); don't report a live session over a dead socket.
      if (ws.readyState !== WebSocket.OPEN) {
        return failStart(
          new SttLifecycleError({
            kind: "provider-unavailable",
            message: "The streaming session closed before audio could start",
          }),
        );
      }

      state = "open";
    },

    async stop(): Promise<void> {
      if (state === "stopped") return;
      if (state === "idle") {
        state = "stopped";
        return;
      }
      // "starting" or "open": signal any in-flight start to abort, release the
      // mic + socket, and stop delivering events.
      stopRequested = true;
      state = "stopped";
      await teardown();
      listener = null;
    },
  };
}
