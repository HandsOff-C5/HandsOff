import type { CapabilityId, CapabilityReadiness, ReadinessLevel } from "@handsoff/contracts";
import { describe, expect, it } from "vitest";

import { EDUCATED_PERMISSION_IDS, permissionEducation, permissionSetupState } from "./education";

// Minimal CapabilityReadiness — the education lookup only reads id and level.
const readiness = (id: CapabilityId, level: ReadinessLevel): CapabilityReadiness => ({
  id,
  label: id,
  level,
  status: "test",
});

const NOT_READY: ReadinessLevel[] = ["blocked", "attention"];

describe("EDUCATED_PERMISSION_IDS", () => {
  it("covers the macOS TCC grants that gate head pointing and computer-use actions", () => {
    expect([...EDUCATED_PERMISSION_IDS]).toEqual(["camera", "accessibility", "screen-recording"]);
  });
});

describe("permissionEducation — Camera", () => {
  it.each(NOT_READY)("returns targeted guidance when %s", (level) => {
    const guidance = permissionEducation(readiness("camera", level));
    expect(guidance).toBeDefined();
    expect(guidance?.settingsPath).toContain("Camera");
    expect(guidance?.reason).toContain("Head pointing");
    expect(guidance?.steps.length).toBeGreaterThan(0);
  });

  it("returns no guidance once granted", () => {
    expect(permissionEducation(readiness("camera", "ready"))).toBeUndefined();
  });
});

describe("permissionEducation — Accessibility", () => {
  it.each(NOT_READY)("returns targeted guidance when %s", (level) => {
    const guidance = permissionEducation(readiness("accessibility", level));
    expect(guidance).toBeDefined();
    expect(guidance?.settingsPath).toContain("Accessibility");
    expect(guidance?.reason).toBeTruthy();
    expect(guidance?.steps.length).toBeGreaterThan(0);
    // The guidance routes the user to a re-check after granting.
    expect(guidance?.steps.some((step) => /re-check/i.test(step))).toBe(true);
  });

  it("returns no guidance once granted", () => {
    expect(permissionEducation(readiness("accessibility", "ready"))).toBeUndefined();
  });
});

describe("permissionEducation — Screen Recording", () => {
  it.each(NOT_READY)("returns targeted guidance when %s", (level) => {
    const guidance = permissionEducation(readiness("screen-recording", level));
    expect(guidance).toBeDefined();
    expect(guidance?.settingsPath).toContain("Screen Recording");
    expect(guidance?.reason).toBeTruthy();
    expect(guidance?.steps.length).toBeGreaterThan(0);
  });

  it("returns no guidance once granted", () => {
    expect(permissionEducation(readiness("screen-recording", "ready"))).toBeUndefined();
  });
});

describe("permissionEducation — capabilities this lane does not own", () => {
  // Microphone/speech authorization and CUA daemon health belong to other lanes,
  // so they carry no setup guidance here regardless of state.
  it.each<CapabilityId>(["microphone", "speech-recognition", "cua"])(
    "returns no guidance for %s even when not ready",
    (id) => {
      expect(permissionEducation(readiness(id, "blocked"))).toBeUndefined();
      expect(permissionEducation(readiness(id, "attention"))).toBeUndefined();
    },
  );
});

describe("permissionSetupState", () => {
  const report = (
    camera: ReadinessLevel,
    accessibility: ReadinessLevel,
    screenRecording: ReadinessLevel,
  ): CapabilityReadiness[] => [
    readiness("camera", camera),
    readiness("accessibility", accessibility),
    readiness("screen-recording", screenRecording),
  ];

  it("reports allReady with nothing to grant when all educated grants are ready", () => {
    const state = permissionSetupState(report("ready", "ready", "ready"));
    expect(state.allReady).toBe(true);
    expect(state.toGrant).toHaveLength(0);
  });

  it("pairs each not-ready grant with its guidance, in display order", () => {
    const state = permissionSetupState(report("blocked", "blocked", "attention"));
    expect(state.allReady).toBe(false);
    expect(state.toGrant.map((item) => item.capability.id)).toEqual([...EDUCATED_PERMISSION_IDS]);
    expect(state.toGrant[0]?.guidance.settingsPath).toContain("Camera");
    expect(state.toGrant[1]?.guidance.settingsPath).toContain("Accessibility");
    expect(state.toGrant[2]?.guidance.settingsPath).toContain("Screen Recording");
  });

  it("surfaces only the blocked grant when the other is ready", () => {
    const state = permissionSetupState(report("ready", "ready", "blocked"));
    expect(state.allReady).toBe(false);
    expect(state.toGrant.map((item) => item.capability.id)).toEqual(["screen-recording"]);
  });

  it("does not claim allReady when the educated grants are absent from the report", () => {
    const state = permissionSetupState([readiness("microphone", "ready")]);
    expect(state.allReady).toBe(false);
    expect(state.toGrant).toHaveLength(0);
  });
});
