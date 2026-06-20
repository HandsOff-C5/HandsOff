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
      "Find HandsOff in the list (use the + button to add it if it isn't there).",
      "Turn the switch next to HandsOff on.",
      "Come back here and choose Re-check.",
    ],
  },
  "screen-recording": {
    reason:
      "HandsOff needs Screen Recording to see the windows you point at and capture target previews before it acts. Without it, perception and previews come back blank.",
    settingsPath: "System Settings → Privacy & Security → Screen Recording",
    steps: [
      "Open System Settings → Privacy & Security → Screen Recording.",
      "Find HandsOff in the list (use the + button to add it if it isn't there).",
      "Turn the switch next to HandsOff on.",
      "Quit and reopen HandsOff if macOS asks, then choose Re-check.",
    ],
  },
};

function isEducatedPermission(id: CapabilityId): id is (typeof EDUCATED_PERMISSION_IDS)[number] {
  return (EDUCATED_PERMISSION_IDS as readonly CapabilityId[]).includes(id);
}

// Targeted setup guidance for a capability that is not yet ready. Returns
// `undefined` for ready capabilities and for capabilities this lane does not own,
// so a caller can render guidance for exactly the macOS grants that still block
// computer-use actions.
export function permissionEducation(
  capability: CapabilityReadiness,
): PermissionGuidance | undefined {
  if (capability.level === "ready") return undefined;
  if (!isEducatedPermission(capability.id)) return undefined;
  return GUIDANCE[capability.id];
}
