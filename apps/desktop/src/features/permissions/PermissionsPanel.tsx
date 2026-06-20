import type { CapabilityReadiness } from "@handsoff/contracts";
import { EDUCATED_PERMISSION_IDS, permissionEducation } from "@handsoff/desktop";

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
// Pure presentation — the screen owns the probe (useReadinessProbe) and passes
// the shared report, in-flight flag, and re-check handler down.
export function PermissionsPanel({ report, isChecking, onRecheck }: PermissionsPanelProps) {
  const byId = new Map(report.map((capability) => [capability.id, capability]));
  const educated = EDUCATED_PERMISSION_IDS.map((id) => byId.get(id)).filter(
    (capability): capability is CapabilityReadiness => capability !== undefined,
  );
  const blocked = educated.filter((capability) => permissionEducation(capability) !== undefined);
  const allGranted = educated.length > 0 && blocked.length === 0;

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

      {allGranted ? (
        <p className="permissions__ok">
          Accessibility and Screen Recording are granted. HandsOff can see the windows you point at
          and act on your behalf.
        </p>
      ) : (
        <ul className="permissions__list">
          {blocked.map((capability) => {
            const guidance = permissionEducation(capability);
            if (!guidance) return null;
            return (
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
            );
          })}
        </ul>
      )}
    </section>
  );
}
