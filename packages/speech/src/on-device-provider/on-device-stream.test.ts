import type { SttStreamEvent } from "@handsoff/contracts";
import { SttLifecycleError } from "@handsoff/contracts";
import { describe, expect, it, vi } from "vitest";

import { createOnDeviceSttStream, ON_DEVICE_STT_EVENT } from "./on-device-stream";

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
    await stream.start((event) => events.push(event));

    expect(listen).toHaveBeenCalledWith(ON_DEVICE_STT_EVENT, expect.any(Function));
    expect(invoke).toHaveBeenCalledWith("stt_ondevice_start");

    emit({ kind: "partial", text: "hel" });
    emit({ kind: "final", text: "hello", confidence: 0.9, latencyMs: 100 });
    expect(events.map((event) => event.kind)).toEqual(["partial", "final"]);
  });

  it("drops control frames like ready/terminated", async () => {
    const { stream, emit } = harness();
    const events: SttStreamEvent[] = [];
    await stream.start((event) => events.push(event));
    emit({ kind: "ready" });
    emit({ kind: "terminated" });
    expect(events).toHaveLength(0);
  });

  it("stop() stops the sidecar, unlistens, and silences further events", async () => {
    const { stream, invoke, unlisten, emit } = harness();
    const events: SttStreamEvent[] = [];
    await stream.start((event) => events.push(event));
    await stream.stop();

    expect(invoke).toHaveBeenCalledWith("stt_ondevice_stop");
    expect(unlisten).toHaveBeenCalledTimes(1);

    emit({ kind: "partial", text: "late" });
    expect(events).toHaveLength(0);
  });

  it("rejects start() on an already-active stream", async () => {
    const { stream } = harness();
    await stream.start(() => {});
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

  it("stop() before any start() is idempotent and touches no command", async () => {
    const { stream, invoke } = harness();
    await stream.stop();
    expect(invoke).not.toHaveBeenCalled();
  });
});
