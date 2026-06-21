import { STT_PROVIDERS, type LocalConfig, type SttProvider } from "@handsoff/contracts";

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
            void updateConfig({ sttProvider: event.target.value as SttProvider })
          }
        >
          {STT_PROVIDERS.map((provider) => (
            <option key={provider} value={provider}>
              {STT_PROVIDER_LABELS[provider]}
            </option>
          ))}
        </select>
      </label>

      <button className="settings__reset" type="button" onClick={() => void resetConfig()}>
        Reset
      </button>
    </section>
  );
}
