import { PointingOverlay } from "./features/overlay/PointingOverlay";
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

// Shell entry. The dashboard is the mission-control window (issue #15); the
// overlay window draws the live pointer on the real desktop (#25 cursor seam).
export function App() {
  return currentWindowLabel() === "overlay" ? <PointingOverlay /> : <Dashboard />;
}
