import { EyeCalibrationScreen } from "./features/eye-calibration/EyeCalibrationScreen";
import { PointingOverlay } from "./features/overlay/PointingOverlay";
import {
  emitCalibrationControl,
  emitOverlayApproval,
  tauriCalibrationListen,
  tauriFusionListen,
  tauriOverlayListen,
  tauriSupervisorListen,
} from "./features/overlay/tauri-overlay";
import { hasTauriBackend } from "./lib/tauri";
import { Dashboard } from "./screens/dashboard/Dashboard";

// Both windows load this same bundle; the Tauri window label decides what to render.
// Outside Tauri (tests/browser) there's no label, so we default to the dashboard.
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

// Shell entry. Overlay-as-UI (#25): the transparent overlay window is the app the
// operator sees — and it ALSO runs the engine (camera/trackers/voice/CUA/calibration)
// headless, off-screen. Running the engine in this VISIBLE window keeps its
// requestAnimationFrame + camera loops at full rate; a hidden window would get them
// throttled/suspended by WebKit (which kills hand tracking + the calibration dwell).
// The engine emits the per-model snapshot + calibration view; PointingOverlay, in the
// same window, listens and paints the HUD / calibration gate over the real desktop.
// A dedicated, self-contained mode: launched with VITE_HANDSOFF_MODE=calibrate
// (`pnpm calibrate`), the overlay window renders ONLY the per-monitor eye-calibration
// screen — its own camera + iris loop, dots across each real monitor, live confidence —
// and none of the normal engine/HUD. This is the "see the eye tracking, calibrate it"
// pass, deliberately isolated from the rest of the UI.
const CALIBRATE_MODE = import.meta.env.VITE_HANDSOFF_MODE === "calibrate";

export function App() {
  const label = currentWindowLabel();

  if (CALIBRATE_MODE && (label === "overlay" || !hasTauriBackend())) {
    return <EyeCalibrationScreen />;
  }

  if (label === "overlay") {
    return (
      <>
        <div className="engine-host" aria-hidden="true">
          <Dashboard />
        </div>
        <PointingOverlay
          listen={tauriOverlayListen}
          fusionListen={tauriFusionListen}
          supervisorListen={tauriSupervisorListen}
          onApprove={() => emitOverlayApproval("allow")}
          onDeny={() => emitOverlayApproval("deny")}
          calibrationListen={tauriCalibrationListen}
          onCalibrationSkip={() => emitCalibrationControl("skip")}
        />
      </>
    );
  }

  // In the real app the hidden `main` window runs nothing — the engine lives in the
  // visible overlay window above. In a browser/tests (no Tauri) render the full
  // dashboard so the mission-control UI is still developable + testable.
  if (hasTauriBackend()) return null;
  return <Dashboard />;
}
