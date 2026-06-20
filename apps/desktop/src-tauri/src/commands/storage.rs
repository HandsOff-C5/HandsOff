use serde::{Deserialize, Serialize};
use std::{fs, io, path::Path};
use tauri::{AppHandle, Manager};

const CONFIG_FILE_NAME: &str = "local-config.json";

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LocalConfig {
    pub stt_provider: SttProvider,
}

// Mirrors `STT_PROVIDERS` in `packages/contracts/src/config.ts`; keep the two in
// sync. Any value that fails to deserialize here (an unknown provider, a drifted
// contract) recovers to the default, so the variants must match the contract.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum SttProvider {
    #[serde(rename = "assemblyai")]
    AssemblyAi,
}

impl Default for LocalConfig {
    fn default() -> Self {
        Self {
            stt_provider: SttProvider::AssemblyAi,
        }
    }
}

fn config_path(app: &AppHandle) -> Result<std::path::PathBuf, String> {
    app.path()
        .app_config_dir()
        .map(|dir| dir.join(CONFIG_FILE_NAME))
        .map_err(|error| format!("Could not resolve the local config directory: {error}"))
}

fn write_config_at_path(path: &Path, config: &LocalConfig) -> Result<(), String> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)
            .map_err(|error| format!("Could not create the local config directory: {error}"))?;
    }
    let body = serde_json::to_string_pretty(config)
        .map_err(|error| format!("Could not encode local config: {error}"))?;
    fs::write(path, format!("{body}\n"))
        .map_err(|error| format!("Could not write local config: {error}"))
}

fn load_config_at_path(path: &Path) -> Result<LocalConfig, String> {
    match fs::read_to_string(path) {
        Ok(body) => match serde_json::from_str::<LocalConfig>(&body) {
            Ok(config) => Ok(config),
            Err(_) => reset_config_at_path(path),
        },
        Err(error) if error.kind() == io::ErrorKind::NotFound => reset_config_at_path(path),
        Err(error) => Err(format!("Could not read local config: {error}")),
    }
}

fn update_config_at_path(path: &Path, config: LocalConfig) -> Result<LocalConfig, String> {
    write_config_at_path(path, &config)?;
    Ok(config)
}

fn reset_config_at_path(path: &Path) -> Result<LocalConfig, String> {
    update_config_at_path(path, LocalConfig::default())
}

#[tauri::command]
pub fn load_local_config(app: AppHandle) -> Result<LocalConfig, String> {
    load_config_at_path(&config_path(&app)?)
}

#[tauri::command]
pub fn update_local_config(app: AppHandle, config: LocalConfig) -> Result<LocalConfig, String> {
    update_config_at_path(&config_path(&app)?, config)
}

#[tauri::command]
pub fn reset_local_config(app: AppHandle) -> Result<LocalConfig, String> {
    reset_config_at_path(&config_path(&app)?)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{
        fs,
        path::PathBuf,
        time::{SystemTime, UNIX_EPOCH},
    };

    fn config_path(test_name: &str) -> PathBuf {
        let unique = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("system time should be available")
            .as_nanos();
        PathBuf::from("target")
            .join("storage-tests")
            .join(format!("{test_name}-{unique}"))
            .join("local-config.json")
    }

    #[test]
    fn load_creates_default_config_when_missing() {
        let path = config_path("missing");

        let config = load_config_at_path(&path).expect("missing config should recover to defaults");

        assert_eq!(config, LocalConfig::default());
        let stored = fs::read_to_string(path).expect("default config should be written");
        assert_eq!(
            serde_json::from_str::<LocalConfig>(&stored).expect("stored config should parse"),
            LocalConfig::default()
        );
    }

    #[test]
    fn update_persists_the_selected_provider() {
        let path = config_path("update");
        let updated = LocalConfig {
            stt_provider: SttProvider::AssemblyAi,
        };

        update_config_at_path(&path, updated.clone()).expect("updated config should be stored");

        assert_eq!(
            load_config_at_path(&path).expect("stored config should load"),
            updated
        );
    }

    #[test]
    fn reset_restores_defaults_without_touching_sibling_files() {
        let path = config_path("reset");
        let sibling = path.with_file_name("unrelated-preferences.json");
        fs::create_dir_all(path.parent().expect("test path should have a parent"))
            .expect("test directory should be created");
        fs::write(&sibling, "keep me").expect("sibling sentinel should be written");

        let reset = reset_config_at_path(&path).expect("reset should restore defaults");

        assert_eq!(reset, LocalConfig::default());
        assert_eq!(
            load_config_at_path(&path).expect("reset config should load"),
            LocalConfig::default()
        );
        assert_eq!(
            fs::read_to_string(sibling).expect("sibling file should remain"),
            "keep me"
        );
    }

    #[test]
    fn invalid_config_recovers_to_defaults() {
        let path = config_path("invalid");
        fs::create_dir_all(path.parent().expect("test path should have a parent"))
            .expect("test directory should be created");
        fs::write(&path, r#"{"sttProvider":"ambient"}"#)
            .expect("invalid config should be written");

        let recovered = load_config_at_path(&path).expect("invalid config should recover");

        assert_eq!(recovered, LocalConfig::default());
        let stored = fs::read_to_string(path).expect("recovered default should be written");
        assert_eq!(
            serde_json::from_str::<LocalConfig>(&stored).expect("stored config should parse"),
            LocalConfig::default()
        );
    }
}
