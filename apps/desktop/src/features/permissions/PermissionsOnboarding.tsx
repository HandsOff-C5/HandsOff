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
  // Fire the OS Screen Recording prompt (also registers the app in its list).
  onRequestScreenRecording: () => Promise<void>;
  // Re-probe permission state after the user grants something.
  onRecheck: () => void;
  // Deep-link the System Settings pane for a manual-only capability.
  onOpenSettings: (id: CapabilityId) => void;
  // Relaunch the app so a Screen Recording / Accessibility grant takes effect.
  onRelaunch: () => void;
  // Close the onboarding (Continue when ready, or Skip for now).
  onDismiss: () => void;
}

// First-run permission onboarding (#18/#56). macOS won't grant several TCC
// permissions in one prompt, so this walks the user through them in one guided
// flow. A single "Grant permissions" fires the no-restart prompts (camera, mic,
// speech) back-to-back. Screen Recording gets its own button because granting it
// forces an app restart — kept out of the batch so it can't kill the flow mid-
// way — and Accessibility deep-links to Settings (macOS has no programmatic
// grant for it). A one-click Relaunch makes the required restart painless.
export function PermissionsOnboarding({
  report,
  isChecking,
  onRequestCamera,
  onRequestMedia,
  onRequestScreenRecording,
  onRecheck,
  onOpenSettings,
  onRelaunch,
  onDismiss,
}: PermissionsOnboardingProps) {
  const plan = planPermissionOnboarding(report);
  const [isGranting, setIsGranting] = useState(false);

  const grantBatch = async () => {
    setIsGranting(true);
    try {
      // Sequential so each OS prompt is answered before the next appears. Screen
      // recording is intentionally excluded — it forces a restart and is granted
      // from its own button.
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
          {plan.steps.map(({ capability, action, done, restartAfter, optional }) => (
            <li
              key={capability.id}
              className={`onboarding__step onboarding__step--${done ? "done" : "pending"}`}
            >
              <span className="onboarding__step-icon" aria-hidden="true">
                {done ? "✅" : "○"}
              </span>
              <span className="onboarding__step-label">{capability.label}</span>
              {optional && <span className="onboarding__step-optional">optional</span>}
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
              {!done && action === "request" && restartAfter && (
                <button
                  type="button"
                  className="onboarding__step-action"
                  onClick={() => void onRequestScreenRecording()}
                >
                  Enable (needs relaunch)
                </button>
              )}
            </li>
          ))}
        </ul>

        <div className="onboarding__actions">
          {plan.batchRequestablePending.length > 0 && (
            <button
              type="button"
              className="onboarding__grant"
              onClick={() => void grantBatch()}
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
          <button type="button" className="onboarding__relaunch" onClick={onRelaunch}>
            Relaunch {APP_NAME}
          </button>
          {plan.requiredReady ? (
            <button type="button" className="onboarding__continue" onClick={onDismiss}>
              All set — continue
            </button>
          ) : (
            <button type="button" className="onboarding__skip" onClick={onDismiss}>
              Skip for now
            </button>
          )}
        </div>

        {plan.restartRequiredPending.length > 0 && (
          <p className="onboarding__note">
            Screen Recording is only used by the agent&apos;s own screenshots (handled by the
            separate CuaDriver app, granted once in System Settings). {APP_NAME} itself doesn&apos;t
            record your screen, so you can continue without it.
          </p>
        )}
        {plan.manualPending.length > 0 && (
          <p className="onboarding__note">
            Accessibility can only be turned on in System Settings — open it, switch {APP_NAME} on,
            then Relaunch (a rebuild can reset it; a signed release removes this churn).
          </p>
        )}
      </section>
    </div>
  );
}
