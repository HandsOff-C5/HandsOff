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
});
