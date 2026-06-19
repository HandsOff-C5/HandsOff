import { PlanPreviewPanel } from "../../features/plan-preview/PlanPreviewPanel";
import { ReadinessPanel } from "../../features/readiness/ReadinessPanel";
import { SessionsPanel } from "../../features/sessions/SessionsPanel";
import { SurfacesPanel } from "../../features/surfaces/SurfacesPanel";

// Mission-control dashboard shell (issue #15). Branded header plus one empty
// placeholder panel per core-loop concern. Visual only — no data, no logic.
export function Dashboard() {
  return (
    <main className="dashboard">
      <header className="dashboard__header">
        <h1 className="dashboard__brand">HandsOff</h1>
        <p className="dashboard__tagline">Point. Speak. Supervise your agents.</p>
      </header>
      <div className="dashboard__panels">
        <ReadinessPanel />
        <SurfacesPanel />
        <SessionsPanel />
        <PlanPreviewPanel />
      </div>
    </main>
  );
}
