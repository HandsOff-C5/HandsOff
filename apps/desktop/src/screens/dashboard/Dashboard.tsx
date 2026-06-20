import { PermissionsPanel } from "../../features/permissions/PermissionsPanel";
import { PlanPreviewPanel } from "../../features/plan-preview/PlanPreviewPanel";
import { ReadinessPanel } from "../../features/readiness/ReadinessPanel";
import { useReadinessProbe } from "../../features/readiness/useReadinessProbe";
import { SessionsPanel } from "../../features/sessions/SessionsPanel";
import { SettingsPanel } from "../../features/settings/SettingsPanel";

// Mission-control dashboard shell (issue #15). Branded header plus one panel per
// core-loop concern. Readiness (#17) and permission education (#18) share one
// host probe: the readiness panel shows status at a glance, the permissions panel
// turns missing macOS grants into targeted setup steps and a re-check.
export function Dashboard() {
  const { report, isChecking, recheck } = useReadinessProbe();
  return (
    <main className="dashboard">
      <header className="dashboard__header">
        <h1 className="dashboard__brand">HandsOff</h1>
        <p className="dashboard__tagline">Point. Speak. Supervise your agents.</p>
      </header>
      <div className="dashboard__panels">
        <ReadinessPanel report={report} />
        <PermissionsPanel report={report} isChecking={isChecking} onRecheck={recheck} />
        <SettingsPanel />
        <SessionsPanel />
        <PlanPreviewPanel />
      </div>
    </main>
  );
}
