import type {
  SttConfidence,
  SttError,
  SttLatencyMs,
  SttStream,
  SttStreamEvent,
  SttStreamListener,
} from "@handsoff/contracts";
import { SttLifecycleError } from "@handsoff/contracts";

// Deterministic mock of the `SttStream` contract (#30) for cross-package tests.
//
// Real streaming STT is non-deterministic (network, audio, provider latency),
// which makes transcript UI and intent-parsing tests flaky. `FakeSttStream`
// lets a test drive the exact event sequence — partials, a final, mid-stream
// errors — with a controllable clock and explicit lifecycle state. It satisfies
// `SttStream` so any consumer written against the contract can be tested
// without a real provider (per #30's scope boundary: no real provider here).
//
// The fake does *not* auto-play a script: tests call `emitPartial`,
// `emitFinal`, and `emitError` to advance the stream. This keeps ordering
// explicit and assertions local to the test's arrange/act/assert.

export type FakeSttStreamState = "idle" | "open" | "stopped";

export interface FakeSttStreamOptions {
  // Injectable clock (epoch ms) so receivedAt timestamps are deterministic.
  // Defaults to Date.now.
  readonly clock?: () => number;
  // When set, start() rejects with an SttLifecycleError carrying this error,
  // and the stream transitions straight to "stopped".
  readonly startError?: SttError;
}

// Distributive Omit — `Omit<Union, K>` would keep only shared keys; this
// preserves each member's own shape minus the omitted key, so an emit can carry
// `text`/`confidence` (transcript) or `error` (error event).
type EmitInput = SttStreamEvent extends infer T
  ? T extends unknown
    ? Omit<T, "receivedAt">
    : never
  : never;

export class FakeSttStream implements SttStream {
  private listener: SttStreamListener | null = null;
  private readonly clock: () => number;
  private readonly startError: SttError | undefined;
  private readonly emitted: SttStreamEvent[] = [];
  private startCalls = 0;
  private stopCalls = 0;
  private currentState: FakeSttStreamState = "idle";

  constructor(options: FakeSttStreamOptions = {}) {
    this.clock = options.clock ?? (() => Date.now());
    this.startError = options.startError;
  }

  get state(): FakeSttStreamState {
    return this.currentState;
  }

  get startCallCount(): number {
    return this.startCalls;
  }

  get stopCallCount(): number {
    return this.stopCalls;
  }

  // Every event the fake has emitted, in order. Useful for asserting that a
  // consumer (e.g. intent fusion) saw the expected sequence.
  get emittedEvents(): readonly SttStreamEvent[] {
    return this.emitted;
  }

  async start(listener: SttStreamListener): Promise<void> {
    this.startCalls += 1;
    if (this.currentState === "open") {
      throw new SttLifecycleError({
        kind: "start-failed",
        message: "FakeSttStream: start() called on an already-open stream",
      });
    }
    if (this.startError !== undefined) {
      this.currentState = "stopped";
      throw new SttLifecycleError(this.startError);
    }
    this.listener = listener;
    this.currentState = "open";
  }

  async stop(): Promise<void> {
    this.stopCalls += 1;
    this.currentState = "stopped";
    this.listener = null;
  }

  // --- test controls -----------------------------------------------------

  emitPartial(text: string, confidence: SttConfidence = 1, latencyMs: SttLatencyMs = 0): void {
    this.emit({ kind: "partial", text, confidence, latencyMs });
  }

  emitFinal(text: string, confidence: SttConfidence = 1, latencyMs: SttLatencyMs = 0): void {
    this.emit({ kind: "final", text, confidence, latencyMs });
  }

  emitError(error: SttError): void {
    this.emit({ kind: "error", error });
  }

  private emit(event: EmitInput): void {
    if (this.currentState !== "open" || this.listener === null) {
      throw new Error(
        `FakeSttStream: cannot emit while state is "${this.currentState}" — call start() first, or stop() is already in effect`,
      );
    }
    const full = { ...event, receivedAt: this.clock() } as SttStreamEvent;
    this.emitted.push(full);
    this.listener(full);
  }
}
