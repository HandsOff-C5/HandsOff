import { APP_NAME } from "@handsoff/contracts";
import type { CapabilityId, CapabilityReadiness, PermissionGuidance } from "@handsoff/contracts";

// The macOS TCC grants that gate computer-use actions, in display order (issue
// #18). camera/microphone and the CUA daemon are owned by other lanes.
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

export function permissionEducation(
  capability: CapabilityReadiness,
): PermissionGuidance | undefined {
  if (capability.level === "ready") return undefined;
  if (!isEducatedPermission(capability.id)) return undefined;
  return GUIDANCE[capability.id];
}

export interface PermissionToGrant {
  capability: CapabilityReadiness;
  guidance: PermissionGuidance;
}

export interface PermissionSetupState {
  toGrant: PermissionToGrant[];
  // True only when every educated grant is present and ready, so a partial
  // report never reads as a false "all granted".
  allReady: boolean;
}

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
