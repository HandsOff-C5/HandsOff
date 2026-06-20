import { STT_PROVIDERS, type SttProvider } from "@handsoff/contracts";

import { useLocalConfig } from "./useLocalConfig";

const STATUS_COPY = {
  ready: "Ready",
  saved: "Saved locally",
  saving: "Saving...",
  unavailable: "Mac app required",
  error: "Could not save settings",
} as const;

// Display labels for the contract's provider list. Options derive from
// `STT_PROVIDERS`, so a new provider in the contract shows up here once it has a
// label — the menu never drifts from the source of truth.
const STT_PROVIDER_LABELS: Record<SttProvider, string> = {
  assemblyai: "AssemblyAI",
};

export function SettingsPanel() {
  const { config, status, updateConfig, resetConfig } = useLocalConfig();

  return (
    <section className="panel settings">
      <div className="settings__header">
        <h2 className="panel__title">Settings</h2>
        <span className={`settings__status settings__status--${status}`} role="status">
          {STATUS_COPY[status]}
        </span>
      </div>

      <label className="settings__field" htmlFor="settings-stt-provider">
        <span>STT provider</span>
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
