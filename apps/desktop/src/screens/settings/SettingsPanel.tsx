import type { LocalConfig, SttProvider } from "@handsoff/contracts";

import { useLocalConfig } from "./useLocalConfig";

const STATUS_COPY = {
  ready: "Ready",
  saved: "Saved locally",
  saving: "Saving...",
  unavailable: "Mac app required",
  error: "Could not save settings",
} as const;

export function SettingsPanel() {
  const { config, status, updateConfig, resetConfig } = useLocalConfig();

  function update(next: Partial<LocalConfig>) {
    void updateConfig({ ...config, ...next });
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
        <span>STT provider</span>
        <select
          id="settings-stt-provider"
          value={config.sttProvider}
          onChange={(event) => update({ sttProvider: event.target.value as SttProvider })}
        >
          <option value="assemblyai">AssemblyAI</option>
          <option value="mock">Mock</option>
        </select>
      </label>

      <label className="settings__toggle" htmlFor="settings-demo-mode">
        <input
          id="settings-demo-mode"
          type="checkbox"
          checked={config.demoMode}
          onChange={(event) => update({ demoMode: event.target.checked })}
        />
        <span>Demo mode</span>
      </label>

      <button className="settings__reset" type="button" onClick={() => void resetConfig()}>
        Reset
      </button>
    </section>
  );
}
