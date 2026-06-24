import type { CapabilityProbe, PermissionState } from "@handsoff/contracts";
import { describe, expect, it } from "vitest";

import { buildReadinessReport } from "../readiness/map";
import { planPermissionOnboarding } from "./onboarding";

// Build a rendered report from raw permission states, defaulting unlisted
// capabilities to not-determined so each test only states what it cares about.
const report = (states: Partial<Record<string, string>>) => {
  const capabilities = (
    ["camera", "microphone", "speech-recognition", "accessibility", "screen-recording"] as const
  ).map(
    (id): CapabilityProbe => ({
      id,
      kind: "permission",
      state: (states[id] ?? "not-determined") as PermissionState,
    }),
  );
  return buildReadinessReport({ capabilities });
};

describe("planPermissionOnboarding", () => {
  it("walks every onboarding capability, classifying request vs manual", () => {
    const plan = planPermissionOnboarding(report({}));
    expect(plan.steps.map((s) => [s.capability.id, s.action])).toEqual([
      ["camera", "request"],
      ["microphone", "request"],
      ["speech-recognition", "request"],
      ["screen-recording", "request"],
      ["accessibility", "open-settings"],
    ]);
  });

  it("needs onboarding and lists the requestable + manual capabilities still pending", () => {
    const plan = planPermissionOnboarding(report({}));
    expect(plan.needsOnboarding).toBe(true);
    expect(plan.allReady).toBe(false);
    expect(plan.batchRequestablePending).toEqual(["camera", "microphone", "speech-recognition"]);
    expect(plan.restartRequiredPending).toEqual(["screen-recording"]);
    expect(plan.manualPending).toEqual(["accessibility"]);
  });

  it("is fully ready when every onboarding permission is granted", () => {
    const plan = planPermissionOnboarding(
      report({
        camera: "granted",
        microphone: "granted",
        "speech-recognition": "granted",
        accessibility: "granted",
        "screen-recording": "granted",
      }),
    );
    expect(plan.allReady).toBe(true);
    expect(plan.needsOnboarding).toBe(false);
    expect(plan.batchRequestablePending).toEqual([]);
    expect(plan.restartRequiredPending).toEqual([]);
    expect(plan.manualPending).toEqual([]);
  });

  it("drops a granted capability from pending and marks its step done", () => {
    const plan = planPermissionOnboarding(report({ camera: "granted" }));
    expect(plan.steps.find((s) => s.capability.id === "camera")?.done).toBe(true);
    expect(plan.batchRequestablePending).toEqual(["microphone", "speech-recognition"]);
    expect(plan.restartRequiredPending).toEqual(["screen-recording"]);
    expect(plan.needsOnboarding).toBe(true);
  });

  // Screen Recording is OPTIONAL: HandsOff's own app never captures the screen
  // (only the separately-signed cua-driver daemon does), so a denied Screen
  // Recording grant must not gate readiness or hold `requiredReady` false. The
  // step is still surfaced (so the user can enable it) but flagged optional.
  it("flags screen-recording optional and keeps requiredReady independent of it", () => {
    const plan = planPermissionOnboarding(
      report({
        camera: "granted",
        microphone: "granted",
        "speech-recognition": "granted",
        accessibility: "granted",
        "screen-recording": "denied",
      }),
    );
    expect(plan.steps.find((s) => s.capability.id === "screen-recording")?.optional).toBe(true);
    expect(plan.steps.find((s) => s.capability.id === "camera")?.optional).toBe(false);
    // Every REQUIRED permission is granted, so the core loop is ready even though
    // the optional Screen Recording grant is still pending.
    expect(plan.requiredReady).toBe(true);
    expect(plan.optionalPending).toEqual(["screen-recording"]);
    // `allReady` (every covered step, incl. optional) is still false while SR pends.
    expect(plan.allReady).toBe(false);
    // The modal still surfaces (so the Enable button is reachable), but only the
    // optional capability is outstanding.
    expect(plan.needsOnboarding).toBe(true);
  });

  it("requiredReady is false while a required permission is still pending", () => {
    const plan = planPermissionOnboarding(
      report({
        camera: "granted",
        microphone: "granted",
        "speech-recognition": "granted",
        "screen-recording": "granted",
        // accessibility still not-determined → required, still pending
      }),
    );
    expect(plan.requiredReady).toBe(false);
    expect(plan.optionalPending).toEqual([]);
  });
});
