import type { SttStream, SttStreamListener } from "@handsoff/contracts";
import { SttLifecycleError } from "@handsoff/contracts";

import { mapOnDeviceEvent } from "./map-event";

// macOS on-device STT provider implementing the `SttStream` contract (#31, AD2).
//
// This is the *default* provider: no API key, no network, no provisioning.
// Recognition runs in a native Swift sidecar (SFSpeechRecognizer + AVAudioEngine)
// that the Rust `stt_ondevice_start` / `stt_ondevice_stop` commands spawn and
// stop; the sidecar's JSON events are forwarded to the webview on the
// `stt://event` Tauri event. This adapter subscribes to that event and invokes
// those commands.
//
// `invoke` and `listen` are injected — the desktop app supplies the real Tauri
// bindings, tests supply fakes — so this package keeps no hard `@tauri-apps/api`
// dependency, mirroring how the AssemblyAI provider takes an injected token +
// socket.

export const ON_DEVICE_STT_EVENT = "stt://event";

export type InvokeFn = (command: string) => Promise<unknown>;
export type ListenEvent = { readonly payload: unknown };
export type ListenFn = (
  event: string,
  handler: (event: ListenEvent) => void,
) => Promise<() => void>;

export interface OnDeviceSttOptions {
  readonly invoke: InvokeFn;
  readonly listen: ListenFn;
}

type State = "idle" | "starting" | "open" | "stopped";

export function createOnDeviceSttStream(options: OnDeviceSttOptions): SttStream {
  let state: State = "idle";
  let listener: SttStreamListener | null = null;
  let unlisten: (() => void) | null = null;
  let startMs = 0;
  // Set when stop() races an in-flight start() so the pending start tears down
  // instead of resurrecting an abandoned session.
  let stopRequested = false;

  function teardown(): void {
    if (unlisten) {
      unlisten();
      unlisten = null;
    }
  }

  // Abort an in-flight start() that stop() cancelled — release the listener and
  // reject with `aborted` (no transcripts emitted), matching the contract.
  function abortStart(): never {
    teardown();
    listener = null;
    state = "stopped";
    throw new SttLifecycleError({
      kind: "aborted",
      message: "Listening was stopped before recognition started",
    });
  }

  return {
    async start(nextListener: SttStreamListener): Promise<void> {
      if (state === "open" || state === "starting") {
        throw new SttLifecycleError({
          kind: "start-failed",
          message: "start() called on an already-active on-device stream",
        });
      }
      state = "starting";
      stopRequested = false;
      listener = nextListener;
      startMs = Date.now();

      // Subscribe before starting recognition so no early partial is missed.
      unlisten = await options.listen(ON_DEVICE_STT_EVENT, ({ payload }) => {
        if (!listener) return;
        const event = mapOnDeviceEvent(payload, { startMs, now: Date.now() });
        if (event) listener(event);
      });
      if (stopRequested) abortStart();

      try {
        await options.invoke("stt_ondevice_start");
      } catch (error) {
        teardown();
        listener = null;
        state = "stopped";
        throw new SttLifecycleError({
          kind: "start-failed",
          message: "Could not start on-device recognition",
          cause: error,
        });
      }
      if (stopRequested) abortStart();

      state = "open";
    },

    async stop(): Promise<void> {
      if (state === "stopped") return;
      if (state === "idle") {
        state = "stopped";
        return;
      }
      // "starting" or "open": cancel any in-flight start, stop the sidecar, and
      // release the subscription so no further events fire.
      stopRequested = true;
      state = "stopped";
      try {
        await options.invoke("stt_ondevice_stop");
      } catch {
        // The session is being torn down regardless of a stop() failure.
      }
      teardown();
      listener = null;
    },
  };
}
