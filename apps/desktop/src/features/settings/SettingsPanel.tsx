import {
  HEAD_POINTER_MOVEMENT_MODES,
  STT_PROVIDERS,
  type HeadPointerMovementMode,
  type LocalConfig,
  type SttProvider,
} from "@handsoff/contracts";

import type { LocalConfigStatus } from "./useLocalConfig";

const STATUS_COPY = {
  ready: "Ready",
  saved: "Saved locally",
  saving: "Saving...",
  unavailable: "Mac app required",
  error: "Could not save settings",
} as const;

// User-facing labels for the two transcription modes (AD2). The provider names
// are deliberately hidden: "Native" is macOS on-device recognition, "Realtime"
// is hosted streaming. Options derive from `STT_PROVIDERS`, so a new mode shows
// up here once it has a label — the menu never drifts from the contract.
const STT_PROVIDER_LABELS: Record<SttProvider, string> = {
  native: "Native",
  assemblyai: "Realtime",
};

const HEAD_POINTER_MOVEMENT_LABELS: Record<HeadPointerMovementMode, string> = {
  edge: "Edge",
  relative: "Relative",
  absolute: "Absolute (hold to aim)",
};

interface SettingsPanelProps {
  config: LocalConfig;
  status: LocalConfigStatus;
  updateConfig: (next: LocalConfig) => void | Promise<void>;
  resetConfig: () => void | Promise<void>;
}

// Presentational settings view. The dashboard owns the config state (so changing
// the transcription mode immediately re-targets the live stream) and passes it
// down here.
export function SettingsPanel({ config, status, updateConfig, resetConfig }: SettingsPanelProps) {
  function updateHeadPointer(headPointer: LocalConfig["headPointer"]) {
    return updateConfig({ ...config, headPointer });
  }

  return (
    <section className="panel settings">
      <div className="settings__header">
        <h2 className="panel__title">Settings</h2>
        <span className={`settings__status settings__status--${status}`} role="status">
          {STATUS_COPY[status]}
        </span>
      </div>

      <label className="settings__field" htmlFor="settings-stt-provider">
        <span>Transcription</span>
        <select
          id="settings-stt-provider"
          value={config.sttProvider}
          onChange={(event) =>
            void updateConfig({ ...config, sttProvider: event.target.value as SttProvider })
          }
        >
          {STT_PROVIDERS.map((provider) => (
            <option key={provider} value={provider}>
              {STT_PROVIDER_LABELS[provider]}
            </option>
          ))}
        </select>
      </label>

      <label className="settings__field" htmlFor="settings-head-pointer-mode">
        <span>Head Pointer Mode</span>
        <select
          id="settings-head-pointer-mode"
          value={config.headPointer.movementMode}
          onChange={(event) =>
            void updateHeadPointer({
              ...config.headPointer,
              movementMode: event.target.value as HeadPointerMovementMode,
            })
          }
        >
          {HEAD_POINTER_MOVEMENT_MODES.map((movementMode) => (
            <option key={movementMode} value={movementMode}>
              {HEAD_POINTER_MOVEMENT_LABELS[movementMode]}
            </option>
          ))}
        </select>
      </label>

      <label className="settings__field" htmlFor="settings-head-pointer-speed">
        <span>Head Pointer Speed</span>
        <input
          id="settings-head-pointer-speed"
          type="number"
          min="1"
          max="10"
          step="1"
          value={config.headPointer.speed}
          onChange={(event) => {
            const speed = event.currentTarget.valueAsNumber;
            if (!Number.isNaN(speed)) {
              void updateHeadPointer({ ...config.headPointer, speed });
            }
          }}
        />
      </label>

      <label className="settings__field" htmlFor="settings-head-pointer-distance">
        <span>Distance to Edge</span>
        <input
          id="settings-head-pointer-distance"
          type="number"
          min="0.02"
          max="0.4"
          step="0.01"
          value={config.headPointer.distanceToEdge}
          onChange={(event) => {
            const distanceToEdge = event.currentTarget.valueAsNumber;
            if (!Number.isNaN(distanceToEdge)) {
              void updateHeadPointer({ ...config.headPointer, distanceToEdge });
            }
          }}
        />
      </label>

      <button className="settings__reset" type="button" onClick={() => void resetConfig()}>
        Reset
      </button>
    </section>
  );
}
