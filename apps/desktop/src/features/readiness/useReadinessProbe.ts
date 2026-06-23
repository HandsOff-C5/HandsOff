import { invoke } from "@tauri-apps/api/core";
import { safeParseReadinessProbe, type CapabilityReadiness } from "@handsoff/contracts";
import { buildReadinessReport } from "@handsoff/desktop";
import { useCallback, useEffect, useRef, useState } from "react";

import { hasTauriBackend } from "../../lib/tauri";

// Shown until the first probe resolves and whenever no native backend is
// reachable (browser/jsdom), so the panel never blanks.
const UNKNOWN_REPORT = buildReadinessReport({ capabilities: [] });

export interface ReadinessProbeState {
  report: CapabilityReadiness[];
  isChecking: boolean;
  recheck: () => void;
}

// Probe macOS capability readiness on mount and on demand (recheck, after the
// user changes permissions — issue #18). A malformed payload or unreachable
// backend keeps the last good report rather than blanking it.
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
