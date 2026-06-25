import { describe, expect, it, vi } from "vitest";

import { STT_ERROR_KINDS, SttLifecycleError } from "@handsoff/contracts";
import type { FinalTranscript, SttStreamEvent, TranscriptEvent } from "@handsoff/contracts";

import { FakeSttStream } from "./fake-stt-stream";

// Deterministic clock so receivedAt timestamps are predictable across runs.
function clock() {
  let t = 1_000;
  return () => (t += 1);
}

async function openStream() {
  const stream = new FakeSttStream({ clock: clock() });
  const events: SttStreamEvent[] = [];
  await stream.start((e) => events.push(e));
  return { stream, events };
}

// Narrow a transcript event out of the full stream-event union.
function asTranscript(e: SttStreamEvent): TranscriptEvent {
  if (e.kind === "error") {
    throw new Error(`expected a transcript event, got error: ${e.error.kind}`);
  }
  return e;
}

describe("FakeSttStream — lifecycle", () => {
  it("starts in idle and transitions to open after start()", async () => {
    const stream = new FakeSttStream();
    expect(stream.state).toBe("idle");
    expect(stream.startCallCount).toBe(0);

    await stream.start(() => undefined);
    expect(stream.state).toBe("open");
    expect(stream.startCallCount).toBe(1);
  });

  it("transitions to stopped after stop() and records the call", async () => {
    const stream = new FakeSttStream();
    await stream.start(() => undefined);
    await stream.stop();

    expect(stream.state).toBe("stopped");
    expect(stream.stopCallCount).toBe(1);
  });

  it("stop() is idempotent on an already-stopped stream", async () => {
    const stream = new FakeSttStream();
    await stream.start(() => undefined);
    await stream.stop();
    await stream.stop();

    expect(stream.state).toBe("stopped");
    expect(stream.stopCallCount).toBe(2);
  });

  it("rejects start() on an already-open stream with a typed start-failed error", async () => {
    const stream = new FakeSttStream();
    await stream.start(() => undefined);

    await expect(stream.start(() => undefined)).rejects.toBeInstanceOf(SttLifecycleError);
    try {
      await stream.start(() => undefined);
    } catch (e) {
      expect(e).toBeInstanceOf(SttLifecycleError);
      expect((e as SttLifecycleError).sttError.kind).toBe("start-failed");
    }
  });

  it("rejects start() with the configured startError and lands in stopped", async () => {
    const stream = new FakeSttStream({
      startError: { kind: "mic-permission", message: "denied" },
    });
    await expect(stream.start(() => undefined)).rejects.toBeInstanceOf(SttLifecycleError);
    expect(stream.state).toBe("stopped");

    try {
      await stream.start(() => undefined);
    } catch (e) {
      expect((e as SttLifecycleError).sttError.kind).toBe("mic-permission");
      expect((e as SttLifecycleError).sttError.message).toBe("denied");
    }
  });
});

describe("FakeSttStream — partial and final events", () => {
  it("delivers a partial transcript to the listener with text, confidence, and latency", async () => {
    const { stream, events } = await openStream();
    stream.emitPartial("use thes", 0.6, 42);

    expect(events).toHaveLength(1);
    const partial = asTranscript(events[0]!);
    expect(partial).toMatchObject({
      kind: "partial",
      text: "use thes",
      confidence: 0.6,
      latencyMs: 42,
    });
    expect(typeof partial.receivedAt).toBe("number");
  });

  it("delivers a final transcript after partials, in order", async () => {
    const { stream, events } = await openStream();
    stream.emitPartial("use");
    stream.emitPartial("use these");
    stream.emitFinal("use these to brief the coding agent", 0.95, 300);

    expect(events.map((e) => e.kind)).toEqual(["partial", "partial", "final"]);
    const final = asTranscript(events[2]!) as FinalTranscript;
    expect(final.text).toBe("use these to brief the coding agent");
    expect(final.confidence).toBe(0.95);
    expect(final.latencyMs).toBe(300);
  });

  it("defaults confidence to 1 and latency to 0 when omitted", async () => {
    const { stream, events } = await openStream();
    stream.emitFinal("hello");

    const final = asTranscript(events[0]!) as FinalTranscript;
    expect(final.confidence).toBe(1);
    expect(final.latencyMs).toBe(0);
  });

  it("omits words when none are supplied", async () => {
    const { stream, events } = await openStream();
    stream.emitFinal("hello");
    const final = asTranscript(events[0]!) as FinalTranscript;
    expect(final.words).toBeUndefined();
  });

  it("carries a per-word epoch-ms timeline on emitFinal when supplied", async () => {
    const { stream, events } = await openStream();
    stream.emitFinal("type this", 0.9, 100, [
      { text: "type", startMs: 1000, endMs: 1200, confidence: 0.9 },
      { text: "this", startMs: 1200, endMs: 1500, confidence: 0.8 },
    ]);
    const final = asTranscript(events[0]!) as FinalTranscript;
    expect(final.words?.map((w) => w.text)).toEqual(["type", "this"]);
    expect(final.words?.[1]?.startMs).toBe(1200);
  });

  it("carries words on emitPartial too", async () => {
    const { stream, events } = await openStream();
    stream.emitPartial("type", 0.6, 0, [
      { text: "type", startMs: 1000, endMs: 1200, confidence: 0.6 },
    ]);
    const partial = asTranscript(events[0]!);
    expect(partial.words?.[0]?.text).toBe("type");
  });

  it("records every emitted event in emittedEvents for downstream assertions", async () => {
    const { stream } = await openStream();
    stream.emitPartial("a");
    stream.emitFinal("a b");

    expect(stream.emittedEvents.map((e) => e.kind)).toEqual(["partial", "final"]);
  });

  it("uses the injected clock for receivedAt, advancing deterministically", async () => {
    const { stream, events } = await openStream();
    stream.emitPartial("x");
    stream.emitFinal("x y");

    expect(events[0]!.receivedAt).toBeLessThan(events[1]!.receivedAt);
  });
});

describe("FakeSttStream — errors", () => {
  it("delivers a typed mid-stream error event to the listener", async () => {
    const { stream, events } = await openStream();
    stream.emitError({ kind: "network", message: "socket closed" });

    expect(events).toHaveLength(1);
    const e = events[0]!;
    expect(e.kind).toBe("error");
    if (e.kind === "error") {
      expect(e.error.kind).toBe("network");
      expect(e.error.message).toBe("socket closed");
    }
  });

  it("keeps the stream open after a mid-stream error so the caller decides to stop", async () => {
    const { stream } = await openStream();
    stream.emitError({ kind: "provider-unavailable", message: "503" });
    expect(stream.state).toBe("open");

    stream.emitFinal("still going");
    expect(stream.emittedEvents).toHaveLength(2);
  });

  it("supports every declared SttErrorKind", async () => {
    const { stream, events } = await openStream();
    for (const kind of STT_ERROR_KINDS) {
      stream.emitError({ kind, message: kind });
    }
    expect(events).toHaveLength(STT_ERROR_KINDS.length);
    expect(events.map((e) => (e.kind === "error" ? e.error.kind : e.kind))).toEqual([
      ...STT_ERROR_KINDS,
    ]);
  });
});

describe("FakeSttStream — stop behavior", () => {
  it("throws when emitting after stop() so test mistakes surface", async () => {
    const { stream } = await openStream();
    await stream.stop();

    expect(() => stream.emitPartial("late")).toThrow(/stop/);
    expect(() => stream.emitFinal("late")).toThrow(/stop/);
    expect(() => stream.emitError({ kind: "aborted", message: "x" })).toThrow(/stop/);
  });

  it("throws when emitting before start()", () => {
    const stream = new FakeSttStream();
    expect(() => stream.emitFinal("early")).toThrow(/start/);
  });

  it("does not invoke the listener after stop() resolves", async () => {
    const listener = vi.fn();
    const stream = new FakeSttStream();
    await stream.start(listener);
    await stream.stop();

    // Any attempt to emit is rejected, so the listener cannot be called.
    expect(() => stream.emitPartial("x")).toThrow();
    expect(listener).not.toHaveBeenCalled();
  });
});
