import {
  CAPABILITY_IDS,
  type CapabilityId,
  type CapabilityProbe,
  type PermissionState,
  type DaemonState,
  type ReadinessLevel,
  safeParseReadinessProbe,
} from "@handsoff/contracts";
import { describe, expect, it } from "vitest";

import { buildReadinessReport, mapCapability, readinessColor } from "./map";

const permission = (id: CapabilityId, state: PermissionState): CapabilityProbe => ({
  id,
  kind: "permission",
  state,
});

const daemon = (id: CapabilityId, state: DaemonState): CapabilityProbe => ({
  id,
  kind: "daemon",
  state,
});

describe("mapCapability — permission states", () => {
  const cases: ReadonlyArray<[PermissionState, ReadinessLevel]> = [
    ["granted", "ready"],
    ["denied", "blocked"],
    ["restricted", "blocked"],
    ["not-determined", "attention"],
    ["unknown", "attention"],
  ];

  it.each(cases)("maps %s to %s", (state, level) => {
    expect(mapCapability(permission("camera", state)).level).toBe(level);
  });

  it("carries a hint for every non-ready permission state", () => {
    for (const [state] of cases) {
      const result = mapCapability(permission("microphone", state));
      if (result.level === "ready") {
        expect(result.hint).toBeUndefined();
      } else {
        expect(result.hint).toBeTruthy();
      }
    }
  });

  it("uses the human label for the capability", () => {
    expect(mapCapability(permission("screen-recording", "granted")).label).toBe("Screen Recording");
    expect(mapCapability(permission("speech-recognition", "granted")).label).toBe(
      "Speech Recognition",
    );
  });
});

describe("mapCapability — daemon states (CUA)", () => {
  const cases: ReadonlyArray<[DaemonState, ReadinessLevel]> = [
    ["running", "ready"],
    ["stopped", "attention"],
    ["not-installed", "blocked"],
    ["unknown", "attention"],
  ];

  it.each(cases)("maps %s to %s", (state, level) => {
    expect(mapCapability(daemon("cua", state)).level).toBe(level);
  });

  it("labels the daemon capability as the computer-use agent", () => {
    expect(mapCapability(daemon("cua", "running")).label).toBe("Computer-use agent");
  });
});

describe("readinessColor", () => {
  it("maps levels to the issue's green/yellow/red", () => {
    expect(readinessColor("ready")).toBe("green");
    expect(readinessColor("attention")).toBe("yellow");
    expect(readinessColor("blocked")).toBe("red");
  });
});

describe("buildReadinessReport", () => {
  it("renders every capability exactly once, in a fixed order", () => {
    const report = buildReadinessReport({ capabilities: [] });
    expect(report.map((c) => c.id)).toEqual([...CAPABILITY_IDS]);
  });

  it("fills a missing capability with the correct unknown kind", () => {
    const report = buildReadinessReport({ capabilities: [] });
    const cua = report.find((c) => c.id === "cua");
    const camera = report.find((c) => c.id === "camera");
    // Daemon-kind unknown speaks about reachability; permission-kind about reads.
    expect(cua?.level).toBe("attention");
    expect(cua?.hint).toContain("reach");
    expect(camera?.level).toBe("attention");
    expect(camera?.hint).toContain("read");
  });

  it("is order-independent and reflects supplied states", () => {
    const report = buildReadinessReport({
      capabilities: [
        daemon("cua", "running"),
        permission("accessibility", "denied"),
        permission("camera", "granted"),
      ],
    });
    expect(report.find((c) => c.id === "camera")?.level).toBe("ready");
    expect(report.find((c) => c.id === "accessibility")?.level).toBe("blocked");
    expect(report.find((c) => c.id === "cua")?.level).toBe("ready");
    // Unsupplied capabilities still appear, as unknown/attention.
    expect(report.find((c) => c.id === "microphone")?.level).toBe("attention");
  });

  it("de-duplicates a repeated capability to its first occurrence", () => {
    const report = buildReadinessReport({
      capabilities: [permission("camera", "granted"), permission("camera", "denied")],
    });
    const cameras = report.filter((c) => c.id === "camera");
    expect(cameras).toHaveLength(1);
    expect(cameras[0]?.level).toBe("ready");
  });
});

describe("safeParseReadinessProbe — boundary validation", () => {
  it("accepts a well-formed probe payload", () => {
    const result = safeParseReadinessProbe({
      capabilities: [{ id: "camera", kind: "permission", state: "granted" }],
    });
    expect(result.success).toBe(true);
  });

  it("rejects an unknown capability id", () => {
    const result = safeParseReadinessProbe({
      capabilities: [{ id: "gps", kind: "permission", state: "granted" }],
    });
    expect(result.success).toBe(false);
  });

  it("rejects a permission state on a daemon kind it does not allow", () => {
    const result = safeParseReadinessProbe({
      capabilities: [{ id: "cua", kind: "daemon", state: "granted" }],
    });
    expect(result.success).toBe(false);
  });

  it("rejects a non-object payload", () => {
    expect(safeParseReadinessProbe(null).success).toBe(false);
    expect(safeParseReadinessProbe("nope").success).toBe(false);
    expect(safeParseReadinessProbe({ capabilities: "no" }).success).toBe(false);
  });
});
