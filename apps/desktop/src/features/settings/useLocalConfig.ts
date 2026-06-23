import { DEFAULT_LOCAL_CONFIG, safeParseLocalConfig, type LocalConfig } from "@handsoff/contracts";
import { invoke } from "@tauri-apps/api/core";
import { useEffect, useState } from "react";

import { hasTauriBackend } from "../../lib/tauri";

export type LocalConfigStatus = "ready" | "saved" | "saving" | "unavailable" | "error";

function parseOrDefault(raw: unknown): LocalConfig {
  const parsed = safeParseLocalConfig(raw);
  return parsed.success ? parsed.data : DEFAULT_LOCAL_CONFIG;
}

export function useLocalConfig() {
  const [config, setConfig] = useState<LocalConfig>(DEFAULT_LOCAL_CONFIG);
  const [status, setStatus] = useState<LocalConfigStatus>(
    hasTauriBackend() ? "ready" : "unavailable",
  );

  useEffect(() => {
    if (!hasTauriBackend()) return;
    let active = true;
    void invoke("load_local_config")
      .then((raw) => {
        if (!active) return;
        setConfig(parseOrDefault(raw));
        setStatus("saved");
      })
      .catch(() => {
        if (active) setStatus("error");
      });
    return () => {
      active = false;
    };
  }, []);

  async function updateConfig(next: LocalConfig) {
    setConfig(next);
    if (!hasTauriBackend()) {
      setStatus("unavailable");
      return;
    }
    setStatus("saving");
    try {
      const raw = await invoke("update_local_config", { config: next });
      setConfig(parseOrDefault(raw));
      setStatus("saved");
    } catch {
      setStatus("error");
    }
  }

  async function resetConfig() {
    if (!hasTauriBackend()) {
      setConfig(DEFAULT_LOCAL_CONFIG);
      setStatus("unavailable");
      return;
    }
    setStatus("saving");
    try {
      const raw = await invoke("reset_local_config");
      setConfig(parseOrDefault(raw));
      setStatus("saved");
    } catch {
      setStatus("error");
    }
  }

  return { config, status, updateConfig, resetConfig };
}
