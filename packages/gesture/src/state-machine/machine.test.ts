import { describe, expect, it } from "vitest";

import { type GestureEvent, type GestureGuards, initialState, reduce } from "./machine";

const candidate = { targetId: "win-1", confidence: 0.9, calibrationQuality: "good" } as const;

// Drive a sequence of [event, guards] pairs from a starting state.
const run = (steps: Array<[GestureEvent, GestureGuards?]>) => {
  let state = initialState();
  const phases: string[] = [];
  for (const [event, guards] of steps) {
    state = reduce(state, event, guards).state;
    phases.push(state.phase);
  }
  return { state, phases };
};

describe("gesture state machine", () => {
  it("starts idle and exposes its phase as a plain value (visible-before-act)", () => {
    expect(initialState().phase).toBe("idle");
  });

  it("point from idle → candidate, remembering the candidate", () => {
    const { state, emit } = reduce(initialState(), { type: "point", candidate });
    expect(state.phase).toBe("candidate");
    expect(state.candidate).toEqual(candidate);
    expect(emit).toBeUndefined();
  });

  it("hold with dwell satisfied → locked, emitting a LockedReferent exactly once", () => {
    const candidateState = reduce(initialState(), { type: "point", candidate }).state;
    const first = reduce(
      candidateState,
      { type: "hold", timestampMs: 1000 },
      { dwellSatisfied: true },
    );
    expect(first.state.phase).toBe("locked");
    expect(first.emit).toEqual({ targetId: "win-1", confidence: 0.9, lockedAtMs: 1000 });

    // A second hold while already locked must NOT re-emit.
    const second = reduce(
      first.state,
      { type: "hold", timestampMs: 1100 },
      { dwellSatisfied: true },
    );
    expect(second.state.phase).toBe("locked");
    expect(second.emit).toBeUndefined();
  });

  it("hold WITHOUT dwell stays in candidate (a single noisy frame can't lock)", () => {
    const s = reduce(initialState(), { type: "point", candidate }).state;
    const r = reduce(s, { type: "hold", timestampMs: 1000 }, { dwellSatisfied: false });
    expect(r.state.phase).toBe("candidate");
    expect(r.emit).toBeUndefined();
  });

  it("cancel from candidate → idle, emitting a cancel intent and clearing the candidate", () => {
    const s = reduce(initialState(), { type: "point", candidate }).state;
    const r = reduce(s, { type: "cancel" });
    expect(r.state.phase).toBe("idle");
    expect(r.emit).toEqual({ kind: "cancel" });
    expect(r.state.candidate).toBeNull();
  });

  it("cancel from locked → idle, emitting a cancel intent", () => {
    let s = reduce(initialState(), { type: "point", candidate }).state;
    s = reduce(s, { type: "hold", timestampMs: 1 }, { dwellSatisfied: true }).state;
    const r = reduce(s, { type: "cancel" });
    expect(r.state.phase).toBe("idle");
    expect(r.emit).toEqual({ kind: "cancel" });
  });

  it("pause and stop → interrupt, emitting the matching intent", () => {
    let s = reduce(initialState(), { type: "point", candidate }).state;
    s = reduce(s, { type: "hold", timestampMs: 1 }, { dwellSatisfied: true }).state;

    const paused = reduce(s, { type: "pause" });
    expect(paused.state.phase).toBe("interrupt");
    expect(paused.emit).toEqual({ kind: "pause" });

    const stopped = reduce(s, { type: "stop" });
    expect(stopped.state.phase).toBe("interrupt");
    expect(stopped.emit).toEqual({ kind: "stop" });
  });

  it("candidate lost / timeout → back to idle (no intent)", () => {
    const s = reduce(initialState(), { type: "point", candidate }).state;
    const r = reduce(s, { type: "lost" });
    expect(r.state.phase).toBe("idle");
    expect(r.emit).toBeUndefined();
    expect(r.state.candidate).toBeNull();
  });

  it("a noisy sequence (point, hold×3 without dwell, lost) never reaches locked", () => {
    const { state, phases } = run([
      [{ type: "point", candidate }],
      [{ type: "hold", timestampMs: 10 }, { dwellSatisfied: false }],
      [{ type: "hold", timestampMs: 20 }, { dwellSatisfied: false }],
      [{ type: "hold", timestampMs: 30 }, { dwellSatisfied: false }],
      [{ type: "lost" }],
    ]);
    expect(phases).not.toContain("locked");
    expect(state.phase).toBe("idle");
  });
});
