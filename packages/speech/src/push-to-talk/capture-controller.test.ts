import type { FinalTranscript, SttError, SttStream, SttStreamListener } from "@handsoff/contracts";
import { FakeSttStream } from "@handsoff/testkit";
import { describe, expect, it, vi } from "vitest";

import { type CaptureStatus, createCaptureController } from "./capture-controller";
import type { TranscriptLatencyRecord } from "../latency";

// A mid-stream error tears down asynchronously (emitError is synchronous, but
// the controller's stop() runs over a few microtasks). Drain the queue so the
// resulting "error" transition has settled before asserting.
async function flush(): Promise<void> {
  for (let i = 0; i < 5; i += 1) await Promise.resolve();
}

// A fresh fake per press() (matching the controller's per-capture stream
// creation), with a handle on the most recent one to drive its events.
function harness(options?: {
  startError?: SttError;
  now?: () => number;
  streamClock?: () => number;
}) {
  const fakes: FakeSttStream[] = [];
  const utterances: FinalTranscript[] = [];
  const partials: string[] = [];
  const statuses: CaptureStatus[] = [];
  const errors: SttError[] = [];
  const latencyRecords: TranscriptLatencyRecord[] = [];

  const controller = createCaptureController(
    () => {
      const fake = new FakeSttStream({
        ...(options?.startError ? { startError: options.startError } : {}),
        ...(options?.streamClock ? { clock: options.streamClock } : {}),
      });
      fakes.push(fake);
      return fake;
    },
    {
      onUtterance: (utterance) => utterances.push(utterance),
      onPartial: (text) => partials.push(text),
      onStatus: (status) => statuses.push(status),
      onError: (error) => errors.push(error),
      onLatency: (record) => latencyRecords.push(record),
      now: options?.now ?? (() => 1000),
    },
  );

  const latest = () => {
    const fake = fakes[fakes.length - 1];
    if (!fake) throw new Error("no fake stream created yet");
    return fake;
  };

  return { controller, fakes, latest, utterances, partials, statuses, errors, latencyRecords };
}

describe("createCaptureController", () => {
  it("delivers one stable final utterance per capture on release", async () => {
    const h = harness();
    await h.controller.press();

    h.latest().emitPartial("open the");
    h.latest().emitFinal("open the issue", 0.9, 120);
    h.latest().emitPartial("and brief the agent");

    await h.controller.release();

    expect(h.utterances).toHaveLength(1);
    expect(h.utterances[0]).toMatchObject({
      kind: "final",
      text: "open the issue and brief the agent",
      confidence: 0.9,
      latencyMs: 120,
      receivedAt: 1000,
    });
    expect(h.controller.status).toBe("idle");
    expect(h.latest().stopCallCount).toBe(1);
  });

  it("records capture-start to final transcript latency on release", async () => {
    const now = vi.fn().mockReturnValueOnce(1000).mockReturnValueOnce(1400);
    const streamClock = vi.fn().mockReturnValueOnce(1100).mockReturnValueOnce(1275);
    const h = harness({ now, streamClock });
    await h.controller.press();
    h.latest().emitPartial("approve", 0.5, 40);
    h.latest().emitFinal("approve the plan", 0.97, 75);

    await h.controller.release();

    expect(h.latencyRecords).toEqual([
      {
        kind: "transcript-latency",
        captureStartedAt: 1000,
        finalReceivedAt: 1275,
        captureToFinalMs: 275,
        finalTranscriptLatencyMs: 75,
        transcriptText: "approve the plan",
        eventCount: 2,
      },
    ]);
  });

  it("includes a provider final emitted during release teardown", async () => {
    let listener: SttStreamListener | null = null;
    const stream: SttStream = {
      async start(next) {
        listener = next;
      },
      async stop() {
        listener?.({
          kind: "final",
          text: "open the dashboard",
          confidence: 0.84,
          latencyMs: 240,
          receivedAt: 900,
        });
        listener = null;
      },
    };
    const utterances: FinalTranscript[] = [];
    const controller = createCaptureController(() => stream, {
      onUtterance: (utterance) => utterances.push(utterance),
      now: () => 1000,
    });

    await controller.press();
    await controller.release();

    expect(utterances).toHaveLength(1);
    expect(utterances[0]).toMatchObject({
      kind: "final",
      text: "open the dashboard",
      confidence: 0.84,
      latencyMs: 240,
    });
  });

  it("joins multiple provider finals into a single utterance", async () => {
    const h = harness();
    await h.controller.press();
    h.latest().emitFinal("open the issue", 0.95, 100);
    h.latest().emitFinal("and the terminal", 0.8, 140);
    await h.controller.release();

    expect(h.utterances).toHaveLength(1);
    expect(h.utterances[0]?.text).toBe("open the issue and the terminal");
    // Weakest segment's confidence, slowest segment's latency.
    expect(h.utterances[0]?.confidence).toBe(0.8);
    expect(h.utterances[0]?.latencyMs).toBe(140);
  });

  it("reports live partials while capturing", async () => {
    const h = harness();
    await h.controller.press();
    h.latest().emitPartial("hel");
    h.latest().emitPartial("hello world");
    expect(h.partials).toEqual(["hel", "hello world"]);
  });

  it("cancel discards the in-flight capture without emitting", async () => {
    const h = harness();
    await h.controller.press();
    h.latest().emitFinal("open the issue", 1, 100);

    await h.controller.cancel();

    expect(h.utterances).toHaveLength(0);
    expect(h.controller.status).toBe("idle");
    expect(h.latest().stopCallCount).toBe(1);
  });

  it("cancel ignores provider finals emitted during teardown", async () => {
    let listener: SttStreamListener | null = null;
    const stream: SttStream = {
      async start(next) {
        listener = next;
      },
      async stop() {
        listener?.({
          kind: "final",
          text: "discard me",
          confidence: 1,
          latencyMs: 10,
          receivedAt: 900,
        });
        listener = null;
      },
    };
    const utterances: FinalTranscript[] = [];
    const controller = createCaptureController(() => stream, {
      onUtterance: (utterance) => utterances.push(utterance),
    });

    await controller.press();
    await controller.cancel();

    expect(utterances).toHaveLength(0);
  });

  it("release with no speech emits nothing", async () => {
    const h = harness();
    await h.controller.press();
    await h.controller.release();
    expect(h.utterances).toHaveLength(0);
    expect(h.controller.status).toBe("idle");
  });

  it("surfaces a mid-stream provider error and stops the stream", async () => {
    const h = harness();
    await h.controller.press();
    h.latest().emitError({ kind: "network", message: "dropped" });
    await flush();

    expect(h.errors).toEqual([{ kind: "network", message: "dropped" }]);
    expect(h.controller.status).toBe("error");
    expect(h.latest().stopCallCount).toBe(1);
  });

  it("recovers: a fresh press after an error starts a new capture", async () => {
    const h = harness();
    await h.controller.press();
    h.latest().emitError({ kind: "network", message: "dropped" });
    await flush();
    expect(h.controller.status).toBe("error");

    await h.controller.press();
    expect(h.controller.status).toBe("capturing");
    h.latest().emitFinal("recovered", 1, 50);
    await h.controller.release();
    expect(h.utterances).toHaveLength(1);
    expect(h.utterances[0]?.text).toBe("recovered");
  });

  it("surfaces a start() rejection as an error", async () => {
    const h = harness({ startError: { kind: "mic-permission", message: "denied" } });
    await h.controller.press();
    expect(h.errors).toEqual([{ kind: "mic-permission", message: "denied" }]);
    expect(h.controller.status).toBe("error");
  });

  it("ignores a re-press while already capturing", async () => {
    const h = harness();
    await h.controller.press();
    await h.controller.press();
    expect(h.fakes).toHaveLength(1);
    expect(h.latest().startCallCount).toBe(1);
  });

  it("ignores release and cancel while idle", async () => {
    const h = harness();
    await h.controller.release();
    await h.controller.cancel();
    expect(h.utterances).toHaveLength(0);
    expect(h.fakes).toHaveLength(0);
    expect(h.controller.status).toBe("idle");
  });

  it("walks the documented status transitions for a normal capture", async () => {
    const now = vi.fn(() => 2000);
    const h = harness({ now });
    await h.controller.press();
    h.latest().emitFinal("go", 1, 10);
    await h.controller.release();
    expect(h.statuses).toEqual(["capturing", "finalizing", "idle"]);
  });
});
