import type { SttError } from "@handsoff/contracts";
import { SttLifecycleError } from "@handsoff/contracts";

import { resampleToPcm16, TARGET_SAMPLE_RATE } from "./resample";

// Microphone capture for the AssemblyAI v3 streaming provider (#31).
//
// Opens the mic via getUserMedia, runs the audio through an AudioContext, and
// emits 16 kHz mono Int16 PCM frames (via the pure `resampleToPcm16`) suitable
// for v3 binary WebSocket frames. The capture wiring is thin I/O glue; all the
// correctness-critical math lives in `resample.ts` and is unit-tested there.
//
// We use a ScriptProcessorNode rather than an AudioWorklet: a worklet needs a
// separately-bundled module URL, which adds build coupling for no behavioral
// gain at demo scale. ScriptProcessor runs inline and works in the Tauri
// webview today. If latency or main-thread contention becomes a problem, the
// resampler is reusable from a worklet without changes.

// ~50 ms of audio per frame at 16 kHz (the v3 minimum is 50 ms). 4096 input
// samples at 44.1/48 kHz lands comfortably above that floor.
const PROCESSOR_BUFFER_SIZE = 4096;

export interface MicCaptureHandle {
  // Stop capture and release the mic + AudioContext. Idempotent.
  stop(): Promise<void>;
}

export interface MicCaptureOptions {
  // Called with each 16 kHz Int16 PCM frame to send over the WebSocket.
  readonly onFrame: (frame: Int16Array) => void;
}

interface MinimalAudioContext {
  readonly sampleRate: number;
  createMediaStreamSource(stream: MediaStream): {
    connect(node: unknown): void;
    disconnect(): void;
  };
  createScriptProcessor(
    bufferSize: number,
    inputChannels: number,
    outputChannels: number,
  ): ScriptProcessorNode;
  close(): Promise<void>;
}

function audioContextCtor(): { new (): MinimalAudioContext } {
  const w = window as unknown as {
    AudioContext?: { new (): MinimalAudioContext };
    webkitAudioContext?: { new (): MinimalAudioContext };
  };
  const Ctor = w.AudioContext ?? w.webkitAudioContext;
  if (!Ctor) {
    throw new SttLifecycleError({
      kind: "start-failed",
      message: "Web Audio is not available in this environment",
    });
  }
  return Ctor;
}

function classifyGetUserMediaError(error: unknown): SttError {
  const name = error instanceof DOMException ? error.name : "";
  if (name === "NotAllowedError" || name === "SecurityError") {
    return { kind: "mic-permission", message: "Microphone access was denied", cause: error };
  }
  return { kind: "start-failed", message: "Could not open the microphone", cause: error };
}

// Open the mic and start emitting 16 kHz Int16 PCM frames. Rejects with an
// `SttLifecycleError` (kind `mic-permission` or `start-failed`) if capture
// cannot start, so the provider can surface a typed, recoverable failure.
export async function startMicCapture(options: MicCaptureOptions): Promise<MicCaptureHandle> {
  let stream: MediaStream;
  try {
    stream = await navigator.mediaDevices.getUserMedia({ audio: true });
  } catch (error) {
    throw new SttLifecycleError(classifyGetUserMediaError(error));
  }

  let context: MinimalAudioContext;
  try {
    const Ctor = audioContextCtor();
    context = new Ctor();
  } catch (error) {
    stream.getTracks().forEach((track) => track.stop());
    if (error instanceof SttLifecycleError) throw error;
    throw new SttLifecycleError({
      kind: "start-failed",
      message: "Could not start the audio context",
      cause: error,
    });
  }

  const inputRate = context.sampleRate;
  let source: ReturnType<MinimalAudioContext["createMediaStreamSource"]>;
  let processor: ScriptProcessorNode;
  try {
    source = context.createMediaStreamSource(stream);
    processor = context.createScriptProcessor(PROCESSOR_BUFFER_SIZE, 1, 1);

    processor.onaudioprocess = (event: AudioProcessingEvent) => {
      const channel = event.inputBuffer.getChannelData(0);
      const frame = resampleToPcm16(channel, inputRate, TARGET_SAMPLE_RATE);
      if (frame.length > 0) options.onFrame(frame);
    };

    source.connect(processor as unknown as AudioNode);
    // ScriptProcessor only fires `onaudioprocess` while connected to a
    // destination; routing through the context keeps the callback alive.
    processor.connect((context as unknown as { destination: AudioNode }).destination);
  } catch (error) {
    // The mic is already live at this point; release it (and the context)
    // before propagating so a graph-construction failure never leaves the
    // microphone recording.
    stream.getTracks().forEach((track) => track.stop());
    await context.close();
    throw new SttLifecycleError({
      kind: "start-failed",
      message: "Could not start the audio graph",
      cause: error,
    });
  }

  let stopped = false;
  return {
    async stop() {
      if (stopped) return;
      stopped = true;
      processor.onaudioprocess = null;
      try {
        processor.disconnect();
        source.disconnect();
      } catch {
        // Already disconnected.
      }
      stream.getTracks().forEach((track) => track.stop());
      await context.close();
    },
  };
}
