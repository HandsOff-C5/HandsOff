import { APP_NAME, type CapabilityReadiness } from "@handsoff/contracts";
import { permissionSetupState } from "@handsoff/desktop";

interface PermissionsPanelProps {
  report: CapabilityReadiness[];
  isChecking: boolean;
  onRecheck: () => void;
}

// Permission education for the two macOS grants that gate computer-use actions
// (issue #18): Accessibility and Screen Recording. When either is missing it
// shows targeted, copy-exact setup guidance; when both are granted it confirms
// HandsOff can see and act. The Re-check button re-probes readiness so the user
// can grant access in System Settings and confirm here without restarting.
//
// Pure presentation — the desktop lane owns which grants matter and their order
// (permissionSetupState); the screen owns the probe (useReadinessProbe) and
// passes the shared report, in-flight flag, and re-check handler down.
export function PermissionsPanel({ report, isChecking, onRecheck }: PermissionsPanelProps) {
  const { toGrant, allReady } = permissionSetupState(report);

  return (
    <section className="panel permissions">
      <div className="permissions__header">
        <h2 className="panel__title">Permissions</h2>
        <button
          className="permissions__recheck"
          type="button"
          onClick={onRecheck}
          disabled={isChecking}
        >
          {isChecking ? "Checking…" : "Re-check"}
        </button>
      </div>

      {allReady ? (
        <p className="permissions__ok">
          Accessibility and Screen Recording are granted. {APP_NAME} can see the windows you point
          at and act on your behalf.
        </p>
      ) : (
        <ul className="permissions__list">
          {toGrant.map(({ capability, guidance }) => (
            <li key={capability.id} className="permissions__item">
              <h3 className="permissions__name">
                {capability.label}
                <span className="permissions__state"> · {capability.status}</span>
              </h3>
              <p className="permissions__reason">{guidance.reason}</p>
              <p className="permissions__path">{guidance.settingsPath}</p>
              <ol className="permissions__steps">
                {guidance.steps.map((step) => (
                  <li key={step}>{step}</li>
                ))}
              </ol>
            </li>
          ))}
        </ul>
      )}
    </section>
  );
}
