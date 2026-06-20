import {
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

const LABELS: Record<CapabilityId, string> = {
  camera: "Camera",
  microphone: "Microphone",
  cua: "Computer-use agent",
  accessibility: "Accessibility",
  "screen-recording": "Screen Recording",
};

// How each capability is measured. Used to fill in capabilities the native
// probe omitted with a correctly-typed `unknown`.
const KIND_BY_ID: Record<CapabilityId, CapabilityProbe["kind"]> = {
  camera: "permission",
  microphone: "permission",
  cua: "daemon",
  accessibility: "permission",
  "screen-recording": "permission",
};

const COLOR_BY_LEVEL: Record<ReadinessLevel, ReadinessColor> = {
  ready: "green",
  attention: "yellow",
  blocked: "red",
};

// Worst-first ordering, so a list of levels can be reduced to the most severe.
const LEVEL_SEVERITY: Record<ReadinessLevel, number> = {
  ready: 0,
  attention: 1,
  blocked: 2,
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
        hint: "Grant access when HandsOff prompts you.",
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
  return { id: probe.id, label: LABELS[probe.id], ...detail };
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
      KIND_BY_ID[id] === "daemon"
        ? { id, kind: "daemon", state: "unknown" }
        : { id, kind: "permission", state: "unknown" };
    return mapCapability(probeForMissing);
  });
}

// The green/yellow/red the issue's acceptance criteria call for.
export function readinessColor(level: ReadinessLevel): ReadinessColor {
  return COLOR_BY_LEVEL[level];
}

// The most severe level across a report — drives an overall readiness summary.
export function worstLevel(report: readonly CapabilityReadiness[]): ReadinessLevel {
  return report.reduce<ReadinessLevel>(
    (worst, c) => (LEVEL_SEVERITY[c.level] > LEVEL_SEVERITY[worst] ? c.level : worst),
    "ready",
  );
}
