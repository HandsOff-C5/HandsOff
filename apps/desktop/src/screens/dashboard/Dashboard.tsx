import { PlanPreviewPanel } from "../../features/plan-preview/PlanPreviewPanel";
import { ReadinessPanel } from "../../features/readiness/ReadinessPanel";
import { useReadinessProbe } from "../../features/readiness/useReadinessProbe";
import { SessionsPanel } from "../../features/sessions/SessionsPanel";

// Mission-control dashboard shell (issue #15). Branded header plus one panel per
// core-loop concern; the readiness panel (issue #17) is wired to the host probe.
export function Dashboard() {
  const readiness = useReadinessProbe();
  return (
    <main className="dashboard">
      <header className="dashboard__header">
        <h1 className="dashboard__brand">HandsOff</h1>
        <p className="dashboard__tagline">Point. Speak. Supervise your agents.</p>
      </header>
      <div className="dashboard__panels">
        <ReadinessPanel report={readiness} />
        <SessionsPanel />
        <PlanPreviewPanel />
      </div>
    </main>
  );
}
