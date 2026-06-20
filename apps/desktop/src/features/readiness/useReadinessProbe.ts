import { invoke } from "@tauri-apps/api/core";
import { safeParseReadinessProbe, type CapabilityReadiness } from "@handsoff/contracts";
import { buildReadinessReport } from "@handsoff/desktop";
import { useEffect, useState } from "react";

// All-unknown baseline. Shown immediately (and in environments without the
// native backend, e.g. a browser or jsdom test) so the panel never blanks.
const UNKNOWN_REPORT = buildReadinessReport({ capabilities: [] });

function hasTauriBackend(): boolean {
  return typeof window !== "undefined" && "__TAURI_INTERNALS__" in window;
}

// Probe the macOS host for capability readiness via the native `readiness_probe`
// command, validate the payload, and map it to the rendered report. Falls back
// to the all-unknown baseline when no backend is reachable or the payload is
// malformed — detection failures degrade to yellow, never to a crash.
export function useReadinessProbe(): CapabilityReadiness[] {
  const [report, setReport] = useState<CapabilityReadiness[]>(UNKNOWN_REPORT);

  useEffect(() => {
    if (!hasTauriBackend()) return;
    let active = true;
    void invoke("readiness_probe")
      .then((raw) => {
        const parsed = safeParseReadinessProbe(raw);
        if (active && parsed.success) {
          setReport(buildReadinessReport(parsed.data));
        }
      })
      .catch(() => {
        // No reachable backend; keep the all-unknown report.
      });
    return () => {
      active = false;
    };
  }, []);

  return report;
}
