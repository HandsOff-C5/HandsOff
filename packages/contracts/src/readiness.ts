import { z } from "zod";

// First-run capability readiness contract (issue #17).
//
// Two layers cross the area boundary here:
//   1. The raw `ReadinessProbe` payload produced by the macOS host (native
//      Tauri command) — untrusted IPC input, so it carries a zod schema.
//   2. The mapped `CapabilityReadiness` the dashboard renders — produced by the
//      desktop lane's pure mapping (`@handsoff/desktop`), consumed by the app.
//
// The capability set mirrors epic #5: camera, microphone, speech recognition
// (the on-device STT permission, #31), the computer-use agent (CUA) daemon, and
// macOS TCC permissions for Accessibility, Screen Recording, and Input Monitoring.

export const CAPABILITY_IDS = [
  "camera",
  "microphone",
  "speech-recognition",
  "cua",
  "accessibility",
  "screen-recording",
  "input-monitoring",
] as const;

export const capabilityIdSchema = z.enum(CAPABILITY_IDS);
export type CapabilityId = z.infer<typeof capabilityIdSchema>;

// Raw authorization outcome for an OS-permission capability. Mirrors the shape
// macOS TCC exposes (granted / denied / not-yet-asked / MDM-restricted), with
// `unknown` reserved for "we could not read it" (e.g. non-macOS, probe error).
export const permissionStateSchema = z.enum([
  "granted",
  "denied",
  "not-determined",
  "restricted",
  "unknown",
]);
export type PermissionState = z.infer<typeof permissionStateSchema>;

// Raw lifecycle state for a daemon/install capability (the CUA agent).
export const daemonStateSchema = z.enum(["running", "stopped", "not-installed", "unknown"]);
export type DaemonState = z.infer<typeof daemonStateSchema>;

// A single capability's raw probe result, discriminated by how it is measured.
export const capabilityProbeSchema = z.discriminatedUnion("kind", [
  z.object({
    id: capabilityIdSchema,
    kind: z.literal("permission"),
    state: permissionStateSchema,
  }),
  z.object({
    id: capabilityIdSchema,
    kind: z.literal("daemon"),
    state: daemonStateSchema,
  }),
]);
export type CapabilityProbe = z.infer<typeof capabilityProbeSchema>;

// The full payload returned by the native readiness probe. Capabilities may be
// missing or arrive in any order; the mapping layer fills gaps with `unknown`.
export const readinessProbeSchema = z.object({
  capabilities: z.array(capabilityProbeSchema),
});
export type ReadinessProbe = z.infer<typeof readinessProbeSchema>;

// Validate an untrusted probe payload (e.g. from the Tauri IPC boundary).
export function safeParseReadinessProbe(
  input: unknown,
): z.SafeParseReturnType<unknown, ReadinessProbe> {
  return readinessProbeSchema.safeParse(input);
}

// Rendered readiness level. Maps to the green / yellow / red the dashboard
// shows: ready = green, attention = yellow, blocked = red.
export type ReadinessLevel = "ready" | "attention" | "blocked";

export type ReadinessColor = "green" | "yellow" | "red";

// The mapped, UI-facing readiness for one capability.
export interface CapabilityReadiness {
  id: CapabilityId;
  label: string;
  level: ReadinessLevel;
  // Short status line, e.g. "Granted" or "Permission denied".
  status: string;
  // One-line next action. Deep, targeted permission education is issue #18.
  hint?: string;
}

// Targeted setup guidance for a macOS permission that gates computer-use actions
// (issue #18). Lane-produced static content, not IPC input, so it carries no schema.
export interface PermissionGuidance {
  reason: string;
  settingsPath: string;
  steps: string[];
}
