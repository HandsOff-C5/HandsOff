import { APP_NAME, type CapabilityId, type CapabilityReadiness } from "@handsoff/contracts";
import { planPermissionOnboarding } from "@handsoff/desktop";
import { useState } from "react";

interface PermissionsOnboardingProps {
  report: CapabilityReadiness[];
  isChecking: boolean;
  // Fire the OS camera prompt (getUserMedia). Resolves once the user responds.
  onRequestCamera: () => Promise<void>;
  // Fire the OS microphone + speech-recognition prompts (one app command).
  onRequestMedia: () => Promise<void>;
  // Re-probe permission state after the user grants something.
  onRecheck: () => void;
  // Deep-link the System Settings pane for a manual-only capability.
  onOpenSettings: (id: CapabilityId) => void;
  // Close the onboarding (Continue when ready, or Skip for now).
  onDismiss: () => void;
}

// First-run permission onboarding (#18/#56). macOS won't grant several TCC
// permissions in one prompt, so this walks the user through them in one guided
// flow: a single "Grant permissions" fires the requestable prompts (camera, mic,
// speech) back-to-back, and the manual-only grants (Accessibility, Screen
// Recording) deep-link into System Settings with a re-check. No user has to hunt
// for a scattered button per the friction Hirom hit testing the bundled app.
export function PermissionsOnboarding({
  report,
  isChecking,
  onRequestCamera,
  onRequestMedia,
  onRecheck,
  onOpenSettings,
  onDismiss,
}: PermissionsOnboardingProps) {
  const plan = planPermissionOnboarding(report);
  const [isGranting, setIsGranting] = useState(false);

  const grantRequestable = async () => {
    setIsGranting(true);
    try {
      // Sequential so each OS prompt is answered before the next appears.
      await onRequestCamera();
      await onRequestMedia();
    } finally {
      setIsGranting(false);
      onRecheck();
    }
  };

  return (
    <div className="onboarding" role="dialog" aria-modal="true" aria-label="Set up permissions">
      <section className="onboarding__card">
        <h2 className="onboarding__title">Set up {APP_NAME}</h2>
        <p className="onboarding__intro">
          {APP_NAME} needs a few macOS permissions to see your gestures, hear your commands, and act
          for you. Grant the prompts below — each is a separate macOS request.
        </p>

        <ul className="onboarding__steps">
          {plan.steps.map(({ capability, action, done }) => (
            <li
              key={capability.id}
              className={`onboarding__step onboarding__step--${done ? "done" : "pending"}`}
            >
              <span className="onboarding__step-icon" aria-hidden="true">
                {done ? "✅" : "○"}
              </span>
              <span className="onboarding__step-label">{capability.label}</span>
              <span className="onboarding__step-status">{capability.status}</span>
              {!done && action === "open-settings" && (
                <button
                  type="button"
                  className="onboarding__step-action"
                  onClick={() => onOpenSettings(capability.id)}
                >
                  Open System Settings
                </button>
              )}
            </li>
          ))}
        </ul>

        <div className="onboarding__actions">
          {plan.requestablePending.length > 0 && (
            <button
              type="button"
              className="onboarding__grant"
              onClick={() => void grantRequestable()}
              disabled={isGranting}
            >
              {isGranting ? "Requesting…" : "Grant permissions"}
            </button>
          )}
          <button
            type="button"
            className="onboarding__recheck"
            onClick={onRecheck}
            disabled={isChecking}
          >
            {isChecking ? "Checking…" : "Re-check"}
          </button>
          {plan.allReady ? (
            <button type="button" className="onboarding__continue" onClick={onDismiss}>
              All set — continue
            </button>
          ) : (
            <button type="button" className="onboarding__skip" onClick={onDismiss}>
              Skip for now
            </button>
          )}
        </div>

        {plan.manualPending.length > 0 && (
          <p className="onboarding__note">
            Accessibility and Screen Recording can only be turned on in System Settings — open each,
            switch {APP_NAME} on, then Re-check. (A signed release removes this step.)
          </p>
        )}
      </section>
    </div>
  );
}
