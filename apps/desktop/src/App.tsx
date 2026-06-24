import { PointingOverlay } from "./features/overlay/PointingOverlay";
import {
  emitCalibrationControl,
  emitOverlayApproval,
  tauriCalibrationListen,
  tauriFusionListen,
  tauriOverlayListen,
  tauriSupervisorListen,
} from "./features/overlay/tauri-overlay";
import { Dashboard } from "./screens/dashboard/Dashboard";

// Both the dashboard and the full-screen pointing overlay load this same bundle;
// the Tauri window label decides which to render. Outside Tauri (tests/browser)
// there's no label, so we default to the dashboard.
function currentWindowLabel(): string {
  if (typeof window === "undefined" || !("__TAURI_INTERNALS__" in window)) return "main";
  try {
    const internals = (
      window as {
        __TAURI_INTERNALS__?: { metadata?: { currentWindow?: { label?: string } } };
      }
    ).__TAURI_INTERNALS__;
    return internals?.metadata?.currentWindow?.label ?? "main";
  } catch {
    return "main";
  }
}

// Shell entry. Overlay-as-UI (#25): the transparent supervisor HUD window is the
// app the operator sees — it subscribes to the engine's per-model snapshot and
// paints every tracker + the agent on the real desktop, and its approval chip
// sends the verdict back to the hidden engine window. The `main` window runs that
// engine (camera/trackers/voice/CUA) headless and never shows.
export function App() {
  return currentWindowLabel() === "overlay" ? (
    <PointingOverlay
      listen={tauriOverlayListen}
      fusionListen={tauriFusionListen}
      supervisorListen={tauriSupervisorListen}
      onApprove={() => emitOverlayApproval("allow")}
      onDeny={() => emitOverlayApproval("deny")}
      calibrationListen={tauriCalibrationListen}
      onCalibrationSkip={() => emitCalibrationControl("skip")}
    />
  ) : (
    <Dashboard />
  );
}
