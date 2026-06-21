import { describe, expect, it } from "vitest";

import { mapOnDeviceEvent } from "./map-event";

const ctx = { startMs: 1000, now: 1200 } as const;

describe("mapOnDeviceEvent", () => {
  it("maps a partial to a partial transcript with zero confidence and elapsed latency", () => {
    expect(mapOnDeviceEvent({ kind: "partial", text: "hello" }, ctx)).toEqual({
      kind: "partial",
      text: "hello",
      confidence: 0,
      latencyMs: 200,
      receivedAt: 1200,
    });
  });

  it("maps a final using the sidecar's confidence and latency", () => {
    expect(
      mapOnDeviceEvent(
        { kind: "final", text: "open the file", confidence: 0.91, latencyMs: 140 },
        ctx,
      ),
    ).toEqual({
      kind: "final",
      text: "open the file",
      confidence: 0.91,
      latencyMs: 140,
      receivedAt: 1200,
    });
  });

  it("falls back to elapsed latency and zero confidence when a final omits them", () => {
    expect(mapOnDeviceEvent({ kind: "final", text: "go" }, ctx)).toEqual({
      kind: "final",
      text: "go",
      confidence: 0,
      latencyMs: 200,
      receivedAt: 1200,
    });
  });

  it("maps an error with a known kind", () => {
    expect(
      mapOnDeviceEvent({ kind: "error", errorKind: "mic-permission", message: "denied" }, ctx),
    ).toEqual({
      kind: "error",
      error: { kind: "mic-permission", message: "denied" },
      receivedAt: 1200,
    });
  });

  it("coerces an unknown error kind to provider-unavailable", () => {
    expect(mapOnDeviceEvent({ kind: "error", errorKind: "weird", message: "x" }, ctx)).toEqual({
      kind: "error",
      error: { kind: "provider-unavailable", message: "x" },
      receivedAt: 1200,
    });
  });

  it("supplies a default message when an error omits one", () => {
    expect(mapOnDeviceEvent({ kind: "error", errorKind: "start-failed" }, ctx)).toEqual({
      kind: "error",
      error: { kind: "start-failed", message: "On-device recognition failed" },
      receivedAt: 1200,
    });
  });

  it("returns null for ready/terminated control frames", () => {
    expect(mapOnDeviceEvent({ kind: "ready" }, ctx)).toBeNull();
    expect(mapOnDeviceEvent({ kind: "terminated" }, ctx)).toBeNull();
  });

  it("returns null for non-records and a missing kind", () => {
    expect(mapOnDeviceEvent(null, ctx)).toBeNull();
    expect(mapOnDeviceEvent("partial", ctx)).toBeNull();
    expect(mapOnDeviceEvent({ text: "no kind" }, ctx)).toBeNull();
  });

  it("never reports a negative latency when clocks skew", () => {
    expect(
      mapOnDeviceEvent({ kind: "partial", text: "x" }, { startMs: 5000, now: 4000 }),
    ).toMatchObject({
      latencyMs: 0,
    });
  });
});
