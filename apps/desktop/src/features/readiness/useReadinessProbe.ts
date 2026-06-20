import { invoke } from "@tauri-apps/api/core";
import { safeParseReadinessProbe, type CapabilityReadiness } from "@handsoff/contracts";
import { buildReadinessReport } from "@handsoff/desktop";
import { useCallback, useEffect, useRef, useState } from "react";

// All-unknown baseline. Shown immediately (and in environments without the
// native backend, e.g. a browser or jsdom test) so the panel never blanks.
const UNKNOWN_REPORT = buildReadinessReport({ capabilities: [] });

function hasTauriBackend(): boolean {
  return typeof window !== "undefined" && "__TAURI_INTERNALS__" in window;
}

export interface ReadinessProbeState {
  report: CapabilityReadiness[];
  // True while a probe is in flight, so callers can disable a Re-check control.
  isChecking: boolean;
  // Re-run the host probe — the user invokes this after changing permissions in
  // System Settings (issue #18). A no-op when no native backend is reachable.
  recheck: () => void;
}

// Probe the macOS host for capability readiness via the native `readiness_probe`
// command, validate the payload, and map it to the rendered report. Probes once
// on mount and again whenever `recheck` is called. Falls back to the all-unknown
// baseline when no backend is reachable or the payload is malformed — detection
// failures degrade to yellow, never to a crash, and a failed re-check keeps the
// last good report rather than blanking it.
export function useReadinessProbe(): ReadinessProbeState {
  const [report, setReport] = useState<CapabilityReadiness[]>(UNKNOWN_REPORT);
  const [isChecking, setIsChecking] = useState(false);
  const mounted = useRef(true);

  const recheck = useCallback(() => {
    if (!hasTauriBackend()) return;
    setIsChecking(true);
    void invoke("readiness_probe")
      .then((raw) => {
        const parsed = safeParseReadinessProbe(raw);
        if (mounted.current && parsed.success) {
          setReport(buildReadinessReport(parsed.data));
        }
      })
      .catch(() => {
        // No reachable backend / probe failed; keep the last good report.
      })
      .finally(() => {
        if (mounted.current) setIsChecking(false);
      });
  }, []);

  useEffect(() => {
    mounted.current = true;
    recheck();
    return () => {
      mounted.current = false;
    };
  }, [recheck]);

  return { report, isChecking, recheck };
}
