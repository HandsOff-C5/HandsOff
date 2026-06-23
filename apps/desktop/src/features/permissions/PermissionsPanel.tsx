import { APP_NAME, type CapabilityId, type CapabilityReadiness } from "@handsoff/contracts";
import { permissionSetupState } from "@handsoff/desktop";

// Head+voice media permissions (#31, #95): requested through the app process and
// managed/revoked in System Settings, separate from CUA-gating grants (#18).
const MEDIA_PERMISSION_IDS: readonly CapabilityId[] = [
  "camera",
  "microphone",
  "speech-recognition",
];

interface PermissionsPanelProps {
  report: CapabilityReadiness[];
  isChecking: boolean;
  onRecheck: () => void;
  // Trigger first-run native microphone + speech prompts. Optional so the panel
  // still renders in a backend-less context.
  onRequestMedia?: () => void;
  // Open a System Settings privacy pane to grant or revoke a permission.
  onOpenSettings?: (pane: CapabilityId) => void;
}

// Setup guidance, re-check, and accept/revoke controls for the macOS permissions
// HandsOff needs. Pure presentation; the lane owns the projection, the screen the
// probe, the dashboard the OS actions.
export function PermissionsPanel({
  report,
  isChecking,
  onRecheck,
  onRequestMedia,
  onOpenSettings,
}: PermissionsPanelProps) {
  const { toGrant, allReady } = permissionSetupState(report);
  const mediaCapabilities = MEDIA_PERMISSION_IDS.map((id) =>
    report.find((capability) => capability.id === id),
  ).filter((capability): capability is CapabilityReadiness => capability !== undefined);
  const mediaReady =
    mediaCapabilities.length > 0 &&
    mediaCapabilities.every((capability) => capability.level === "ready");

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

      {/* Camera + microphone + speech for head+voice capture (#31, #95): accept
          through the app-owned OS prompt, manage/revoke in System Settings. */}
      <div className="permissions__media">
        <h3 className="permissions__name">Head Capture Media</h3>
        <p className="permissions__reason">
          Head+voice capture needs camera, microphone, and speech recognition access. Camera frames
          and audio stay on your device.
        </p>
        {mediaCapabilities.map((capability) => (
          <div key={capability.id} className="permissions__media-row">
            <span className="permissions__state">
              {capability.label} · {capability.status}
            </span>
            <button
              type="button"
              className="permissions__manage"
              onClick={() => onOpenSettings?.(capability.id)}
            >
              {capability.level === "ready" ? "Manage" : "Open System Settings"}
            </button>
          </div>
        ))}
        {!mediaReady && (
          <button
            type="button"
            className="permissions__allow"
            onClick={() => onRequestMedia?.()}
            disabled={!onRequestMedia}
          >
            Allow camera, microphone &amp; speech
          </button>
        )}
      </div>

      {/* CUA-gating grants (#18): guidance + ordered setup steps. */}
      {allReady ? (
        <p className="permissions__ok">
          Camera, Accessibility, and Screen Recording are granted. {APP_NAME} can track your head
          point, see the windows you point at, and act on your behalf.
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
              <button
                type="button"
                className="permissions__manage"
                onClick={() => onOpenSettings?.(capability.id)}
                disabled={!onOpenSettings}
              >
                {capability.level === "ready" ? "Manage" : "Open System Settings"}
              </button>
            </li>
          ))}
        </ul>
      )}
    </section>
  );
}
