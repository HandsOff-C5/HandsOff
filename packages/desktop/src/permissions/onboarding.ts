import type { CapabilityId, CapabilityReadiness } from "@handsoff/contracts";

// First-run permission onboarding planner (#18/#56). macOS cannot grant several
// TCC permissions in one prompt, so the dashboard walks the user through them in
// one guided flow. This pure core decides the steps and what's still pending; the
// hook fires the OS requests and the component renders the flow.
//
// REQUESTABLE = an in-app action triggers the OS prompt directly: camera via
// getUserMedia, microphone + speech via the `request_media_permissions` command.
// MANUAL = macOS only grants these via a System Settings toggle (no programmatic
// grant exists), so onboarding deep-links there and re-checks.
export const REQUESTABLE_PERMISSION_IDS = [
  "camera",
  "microphone",
  "speech-recognition",
  "screen-recording",
] as const satisfies readonly CapabilityId[];

// Accessibility is the only grant macOS won't prompt for programmatically — it
// must be toggled in System Settings (an app can't request it), so onboarding
// deep-links there and re-checks. Screen Recording IS requestable
// (CGRequestScreenCaptureAccess), which also registers the app in its list.
export const MANUAL_PERMISSION_IDS = ["accessibility"] as const satisfies readonly CapabilityId[];

// The capabilities the onboarding covers, in display order (requestable first so
// the user can clear them with one "Grant" action before the manual toggles).
export const ONBOARDING_PERMISSION_IDS = [
  ...REQUESTABLE_PERMISSION_IDS,
  ...MANUAL_PERMISSION_IDS,
] as const satisfies readonly CapabilityId[];

// Capabilities macOS only applies to a NEW process — granting them needs an app
// relaunch (Screen Recording always; a freshly-toggled grant in general). These
// are kept out of the batched "Grant" action so a forced restart can't kill the
// flow mid-sequence; each gets its own button plus a relaunch affordance.
export const RESTART_REQUIRED_PERMISSION_IDS = [
  "screen-recording",
] as const satisfies readonly CapabilityId[];

// How a pending capability gets granted: fire an OS prompt, or open Settings.
export type PermissionAction = "request" | "open-settings";

export interface OnboardingStep {
  capability: CapabilityReadiness;
  action: PermissionAction;
  // Already granted (level "ready") — shown as complete, not actionable.
  done: boolean;
  // Granting this only takes effect after an app relaunch (macOS).
  restartAfter: boolean;
}

export interface OnboardingPlan {
  steps: OnboardingStep[];
  // Requestable, no-restart capabilities still pending — the targets of the one
  // batched "Grant" action (camera, microphone, speech).
  batchRequestablePending: CapabilityId[];
  // Requestable capabilities still pending that need a relaunch (screen recording).
  restartRequiredPending: CapabilityId[];
  // Manual capabilities still pending — each needs a Settings deep-link + toggle.
  manualPending: CapabilityId[];
  // Every covered capability is granted.
  allReady: boolean;
  // At least one covered capability is still pending — show the onboarding.
  needsOnboarding: boolean;
}

const isRequestable = (id: CapabilityId): boolean =>
  (REQUESTABLE_PERMISSION_IDS as readonly CapabilityId[]).includes(id);

const needsRestart = (id: CapabilityId): boolean =>
  (RESTART_REQUIRED_PERMISSION_IDS as readonly CapabilityId[]).includes(id);

export function planPermissionOnboarding(report: readonly CapabilityReadiness[]): OnboardingPlan {
  const byId = new Map(report.map((capability) => [capability.id, capability]));
  const steps: OnboardingStep[] = ONBOARDING_PERMISSION_IDS.flatMap((id) => {
    const capability = byId.get(id);
    if (!capability) return [];
    return [
      {
        capability,
        action: isRequestable(id) ? "request" : "open-settings",
        done: capability.level === "ready",
        restartAfter: needsRestart(id),
      },
    ];
  });

  const pending = steps.filter((step) => !step.done);
  return {
    steps,
    batchRequestablePending: pending
      .filter((step) => step.action === "request" && !step.restartAfter)
      .map((step) => step.capability.id),
    restartRequiredPending: pending
      .filter((step) => step.restartAfter)
      .map((step) => step.capability.id),
    manualPending: pending
      .filter((step) => step.action === "open-settings")
      .map((step) => step.capability.id),
    allReady: steps.length > 0 && pending.length === 0,
    needsOnboarding: pending.length > 0,
  };
}
