import { describe, expect, it } from "vitest";

import {
  ObservabilityMemorySink,
  safeParseObservabilityRecord,
  type ObservabilityRecord,
} from "./observability";

const base = {
  timestamp: "2026-06-27T12:00:00.000Z",
  component: "director.loop",
  event: "tool_call_finished",
  sessionId: "session-1",
  correlationId: "corr-1",
  traceId: "trace-1",
  spanId: "span-1",
  attributes: { tool: "click", risk: "read_only" },
};

describe("observability record contract", () => {
  it("accepts the five approved record kinds", () => {
    const records: ObservabilityRecord[] = [
      { ...base, kind: "log", level: "info" },
      { ...base, kind: "span", status: "ok", durationMs: 12 },
      { ...base, kind: "metric", name: "cua.failure.count", value: 1, unit: "count" },
      { ...base, kind: "analytics", stage: "action_completed" },
      { ...base, kind: "error", errorClass: "CuaDriverError", handled: true },
    ];

    for (const record of records) {
      expect(safeParseObservabilityRecord(record).success).toBe(true);
    }
  });

  it("rejects raw private fields before records reach a sink", () => {
    const result = safeParseObservabilityRecord({
      ...base,
      kind: "log",
      level: "info",
      attributes: { transcript: "click the private thing" },
    });

    expect(result.success).toBe(false);
  });

  it("fetches exact records from the local test sink", () => {
    const sink = new ObservabilityMemorySink();
    const record: ObservabilityRecord = {
      ...base,
      kind: "metric",
      name: "stt.latency.ms",
      value: 42,
    };

    sink.emit(record);

    expect(sink.records()).toEqual([record]);
  });
});
