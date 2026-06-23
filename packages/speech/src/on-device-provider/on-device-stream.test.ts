import type { SttStreamEvent } from "@handsoff/contracts";
import { SttLifecycleError } from "@handsoff/contracts";
import { describe, expect, it, vi } from "vitest";

import { createOnDeviceSttStream, ON_DEVICE_STT_EVENT } from "./on-device-stream";

async function flush(): Promise<void> {
  await Promise.resolve();
}

// A fake Tauri backend: captures the event handler so a test can push sidecar
// frames, and records invoke/unlisten calls.
function harness() {
  let handler: ((event: { payload: unknown }) => void) | null = null;
  const unlisten = vi.fn();
  const listen = vi.fn(async (_event: string, next: (event: { payload: unknown }) => void) => {
    handler = next;
    return unlisten;
  });
  const invoke = vi.fn(async () => undefined);
  const stream = createOnDeviceSttStream({ invoke, listen });
  const emit = (payload: unknown) => handler?.({ payload });
  return { stream, invoke, listen, unlisten, emit };
}

describe("createOnDeviceSttStream", () => {
  it("subscribes before starting and forwards mapped events to the listener", async () => {
    const { stream, invoke, listen, emit } = harness();
    const events: SttStreamEvent[] = [];
    const started = stream.start((event) => events.push(event));

    expect(listen).toHaveBeenCalledWith(ON_DEVICE_STT_EVENT, expect.any(Function));
    await flush();
    expect(invoke).toHaveBeenCalledWith("stt_ondevice_start");

    emit({ kind: "ready" });
    await started;

    emit({ kind: "partial", text: "hel" });
    emit({ kind: "final", text: "hello", confidence: 0.9, latencyMs: 100 });
    expect(events.map((event) => event.kind)).toEqual(["partial", "final"]);
  });

  it("drops control frames like ready/terminated", async () => {
    const { stream, emit } = harness();
    const events: SttStreamEvent[] = [];
    const started = stream.start((event) => events.push(event));
    emit({ kind: "ready" });
    await started;
    emit({ kind: "terminated" });
    expect(events).toHaveLength(0);
  });

  it("stop() stops the sidecar, unlistens, and silences further events", async () => {
    const { stream, invoke, unlisten, emit } = harness();
    const events: SttStreamEvent[] = [];
    const started = stream.start((event) => events.push(event));
    emit({ kind: "ready" });
    await started;
    await stream.stop();

    expect(invoke).toHaveBeenCalledWith("stt_ondevice_stop");
    expect(unlisten).toHaveBeenCalledTimes(1);

    emit({ kind: "partial", text: "late" });
    expect(events).toHaveLength(0);
  });

  it("rejects start() on an already-active stream", async () => {
    const { stream } = harness();
    const firstStart = stream.start(() => {});
    await expect(stream.start(() => {})).rejects.toMatchObject({
      sttError: { kind: "start-failed" },
    });
    await stream.stop();
    await expect(firstStart).rejects.toMatchObject({
      sttError: { kind: "aborted" },
    });
  });

  it("rejects start() when the sidecar terminates before reporting ready", async () => {
    const { stream, emit } = harness();
    const started = stream.start(() => {});
    emit({ kind: "terminated" });

    await expect(started).rejects.toMatchObject({
      sttError: {
        kind: "start-failed",
        message: "On-device recognition exited before the microphone was ready",
      },
    });
  });

  it("surfaces a sidecar error before ready as the start failure", async () => {
    const { stream, emit } = harness();
    const started = stream.start(() => {});
    emit({ kind: "error", errorKind: "mic-permission", message: "speech unavailable" });

    await expect(started).rejects.toMatchObject({
      sttError: { kind: "mic-permission", message: "speech unavailable" },
    });
  });

  it("rejects start() on an already-open stream", async () => {
    const { stream, emit } = harness();
    const started = stream.start(() => {});
    emit({ kind: "ready" });
    await started;

    await expect(stream.start(() => {})).rejects.toBeInstanceOf(SttLifecycleError);
  });

  it("surfaces a start-failed lifecycle error and cleans up when the command rejects", async () => {
    const unlisten = vi.fn();
    const listen = vi.fn(async () => unlisten);
    const invoke = vi.fn(async () => {
      throw new Error("no sidecar");
    });
    const stream = createOnDeviceSttStream({ invoke, listen });

    await expect(stream.start(() => {})).rejects.toMatchObject({
      sttError: { kind: "start-failed" },
    });
    expect(unlisten).toHaveBeenCalledTimes(1);
  });

  it("stop() can abort a start that is waiting for native readiness", async () => {
    const { stream, invoke, unlisten } = harness();
    const started = stream.start(() => {});

    await flush();
    await stream.stop();

    await expect(started).rejects.toMatchObject({
      sttError: { kind: "aborted" },
    });
    expect(invoke).toHaveBeenCalledWith("stt_ondevice_stop");
    expect(unlisten).toHaveBeenCalledTimes(1);
  });

  it("stop() before any start() is idempotent and touches no command", async () => {
    const { stream, invoke } = harness();
    await stream.stop();
    expect(invoke).not.toHaveBeenCalled();
  });
});
