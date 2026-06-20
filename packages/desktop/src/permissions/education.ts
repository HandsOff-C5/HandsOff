import { APP_NAME } from "@handsoff/contracts";
import type { CapabilityId, CapabilityReadiness, PermissionGuidance } from "@handsoff/contracts";

// Targeted macOS permission education for the two TCC grants that gate
// computer-use actions (issue #18).
//
// HandsOff's core loop ends in "execute through CUA/agent": the agent moves the
// pointer, clicks, types, and reads the screen on the user's behalf. macOS will
// not let it do any of that without Accessibility and Screen Recording. Those two
// grants are also the only ones this lane educates on — camera/microphone
// authorization lands with the capture/STT lanes, and the CUA daemon health
// check lands with the CUA lane, so they carry no setup guidance here.
//
// Unlike camera/microphone, macOS never auto-prompts for Accessibility or Screen
// Recording from a normal app — the user must toggle them by hand in System
// Settings — so the steps below are the reliable path for every not-granted state.

// The capabilities this lane educates on, in the order they should be shown.
export const EDUCATED_PERMISSION_IDS = ["accessibility", "screen-recording"] as const;

const GUIDANCE: Record<(typeof EDUCATED_PERMISSION_IDS)[number], PermissionGuidance> = {
  accessibility: {
    reason:
      "The computer-use agent needs Accessibility to act for you — move the pointer, click, and type in other apps. Without it, approved plans can't run.",
    settingsPath: "System Settings → Privacy & Security → Accessibility",
    steps: [
      "Open System Settings → Privacy & Security → Accessibility.",
      `Find ${APP_NAME} in the list (use the + button to add it if it isn't there).`,
      `Turn the switch next to ${APP_NAME} on.`,
      "Come back here and choose Re-check.",
    ],
  },
  "screen-recording": {
    reason: `${APP_NAME} needs Screen Recording to see the windows you point at and capture target previews before it acts. Without it, perception and previews come back blank.`,
    settingsPath: "System Settings → Privacy & Security → Screen Recording",
    steps: [
      "Open System Settings → Privacy & Security → Screen Recording.",
      `Find ${APP_NAME} in the list (use the + button to add it if it isn't there).`,
      `Turn the switch next to ${APP_NAME} on.`,
      `Quit and reopen ${APP_NAME} if macOS asks, then choose Re-check.`,
    ],
  },
};

function isEducatedPermission(id: CapabilityId): id is (typeof EDUCATED_PERMISSION_IDS)[number] {
  return (EDUCATED_PERMISSION_IDS as readonly CapabilityId[]).includes(id);
}

// Targeted setup guidance for a capability that is not yet ready. Returns
// `undefined` for ready capabilities and for capabilities this lane does not own.
export function permissionEducation(
  capability: CapabilityReadiness,
): PermissionGuidance | undefined {
  if (capability.level === "ready") return undefined;
  if (!isEducatedPermission(capability.id)) return undefined;
  return GUIDANCE[capability.id];
}

// One educated macOS grant that still needs the user's attention, paired with its
// setup guidance — the exact unit the permissions panel renders.
export interface PermissionToGrant {
  capability: CapabilityReadiness;
  guidance: PermissionGuidance;
}

// The complete render state for the permissions panel (issue #18). The lane owns
// which grants it educates on, their order, and the readiness lookup, so the view
// can render directly without re-deriving any of it.
export interface PermissionSetupState {
  // Educated grants not yet ready, in display order, each with its guidance.
  toGrant: PermissionToGrant[];
  // True only when every educated grant is present in the report and ready, so an
  // empty or partial report never reads as a false "all granted".
  allReady: boolean;
}

// Project a readiness report onto the permission-setup work that remains.
export function permissionSetupState(report: readonly CapabilityReadiness[]): PermissionSetupState {
  const byId = new Map(report.map((capability) => [capability.id, capability]));
  const present = EDUCATED_PERMISSION_IDS.map((id) => byId.get(id)).filter(
    (capability): capability is CapabilityReadiness => capability !== undefined,
  );
  const toGrant = present.flatMap((capability) => {
    const guidance = permissionEducation(capability);
    return guidance ? [{ capability, guidance }] : [];
  });
  const allReady = present.length === EDUCATED_PERMISSION_IDS.length && toGrant.length === 0;
  return { toGrant, allReady };
}
