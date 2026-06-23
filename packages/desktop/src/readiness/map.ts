import {
  APP_NAME,
  CAPABILITY_IDS,
  type CapabilityId,
  type CapabilityProbe,
  type CapabilityReadiness,
  type DaemonState,
  type PermissionState,
  type ReadinessColor,
  type ReadinessLevel,
  type ReadinessProbe,
} from "@handsoff/contracts";

// Pure mapping from a raw capability probe to the green/yellow/red readiness the
// dashboard renders (issue #17). No I/O, no platform calls — this is the
// deterministic core the readiness feature is tested against.

// Per-capability metadata: the display label and how the capability is measured.
// `id` is the single source of truth for `kind` — which decides the state
// vocabulary and how a capability the native probe omitted is filled in.
const CAPABILITIES: Record<CapabilityId, { label: string; kind: CapabilityProbe["kind"] }> = {
  camera: { label: "Camera", kind: "permission" },
  microphone: { label: "Microphone", kind: "permission" },
  "speech-recognition": { label: "Speech Recognition", kind: "permission" },
  cua: { label: "Computer-use agent", kind: "daemon" },
  accessibility: { label: "Accessibility", kind: "permission" },
  "screen-recording": { label: "Screen Recording", kind: "permission" },
  "input-monitoring": { label: "Input Monitoring", kind: "permission" },
};

const COLOR_BY_LEVEL: Record<ReadinessLevel, ReadinessColor> = {
  ready: "green",
  attention: "yellow",
  blocked: "red",
};

type LevelDetail = Pick<CapabilityReadiness, "level" | "status" | "hint">;

function mapPermission(state: PermissionState): LevelDetail {
  switch (state) {
    case "granted":
      return { level: "ready", status: "Granted" };
    case "denied":
      return {
        level: "blocked",
        status: "Permission denied",
        hint: "Enable it in System Settings → Privacy & Security.",
      };
    case "restricted":
      return {
        level: "blocked",
        status: "Restricted by system policy",
        hint: "A device profile or parental control is blocking access.",
      };
    case "not-determined":
      return {
        level: "attention",
        status: "Not requested yet",
        hint: `Grant access when ${APP_NAME} prompts you.`,
      };
    case "unknown":
      return {
        level: "attention",
        status: "Not checked yet",
        hint: "Could not read the permission state.",
      };
  }
}

function mapDaemon(state: DaemonState): LevelDetail {
  switch (state) {
    case "running":
      return { level: "ready", status: "Running" };
    case "stopped":
      return {
        level: "attention",
        status: "Installed but not running",
        hint: "Start the computer-use agent.",
      };
    case "not-installed":
      return {
        level: "blocked",
        status: "Not installed",
        hint: "Install the computer-use agent.",
      };
    case "unknown":
      return {
        level: "attention",
        status: "Not checked yet",
        hint: "Could not reach the computer-use agent.",
      };
  }
}

// Map one raw probe to its rendered readiness.
export function mapCapability(probe: CapabilityProbe): CapabilityReadiness {
  const detail = probe.kind === "permission" ? mapPermission(probe.state) : mapDaemon(probe.state);
  return { id: probe.id, label: CAPABILITIES[probe.id].label, ...detail };
}

// Build the full, fixed-order readiness report. Capabilities absent from the
// probe (or duplicated) resolve to a single `unknown` entry so the dashboard
// always shows every capability exactly once.
export function buildReadinessReport(probe: ReadinessProbe): CapabilityReadiness[] {
  const byId = new Map<CapabilityId, CapabilityProbe>();
  for (const c of probe.capabilities) {
    if (!byId.has(c.id)) byId.set(c.id, c);
  }
  return CAPABILITY_IDS.map((id) => {
    const found = byId.get(id);
    if (found) return mapCapability(found);
    const probeForMissing: CapabilityProbe =
      CAPABILITIES[id].kind === "daemon"
        ? { id, kind: "daemon", state: "unknown" }
        : { id, kind: "permission", state: "unknown" };
    return mapCapability(probeForMissing);
  });
}

// The green/yellow/red the issue's acceptance criteria call for.
export function readinessColor(level: ReadinessLevel): ReadinessColor {
  return COLOR_BY_LEVEL[level];
}
