// Command modules wired into the Tauri builder.
pub mod cua;
pub mod head_track;
pub mod hotkey;
pub mod intent;
pub mod overlay;
pub mod permissions;
pub mod readiness;
pub mod storage;
pub mod stt;
pub mod stt_ondevice;

/// Resolve a piece of deployment config (a Worker URL or app-cohort token).
///
/// Runtime process env wins (so `open --env` / CI can override), then the value
/// baked from `apps/desktop/.env.local` at build time (see `build.rs`), so a
/// `tauri build` produces an app that is fully wired on every launch — Finder,
/// Dock, or `open` — without per-launch flags. Empty strings count as absent.
/// Call sites pass `option_env!("HANDSOFF_…")` for the baked value.
pub(crate) fn deployment_config(env_key: &str, baked: Option<&str>) -> Option<String> {
    if let Ok(value) = std::env::var(env_key) {
        let value = value.trim().to_string();
        if !value.is_empty() {
            return Some(value);
        }
    }
    baked
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(str::to_string)
}
