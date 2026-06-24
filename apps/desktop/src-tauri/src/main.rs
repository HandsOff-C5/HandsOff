// HandsOff desktop shell entry point.
//
// Opens the mission-control dashboard window and wires the commands the frontend
// invokes. Readiness reports host capability state; storage keeps non-secret
// local preferences for settings. CUA exposes a typed unavailable state until
// the live driver transport lands.
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

mod commands;

fn main() {
    // Load local secrets (the gitignored .env) before anything reads them, so the
    // CUA brain finds ANTHROPIC_API_KEY without the user exporting it by hand.
    // Missing/!readable .env is fine — the env may already carry the key, and the
    // brain command reports a clear "missing-credentials" error if it doesn't.
    match dotenvy::dotenv() {
        Ok(path) => eprintln!("handsoff: loaded env from {}", path.display()),
        Err(error) => eprintln!("handsoff: no .env loaded ({error})"),
    }

    tauri::Builder::default()
        .plugin(tauri_plugin_shell::init())
        // Command + Option + / capture hotkey (#95) via the global-shortcut
        // plugin — no Accessibility/Input Monitoring permission needed.
        // Pressed/Released drive capture start/stop through `hotkey://capture`.
        .plugin(
            tauri_plugin_global_shortcut::Builder::new()
                .with_handler(|app, _shortcut, event| {
                    commands::hotkey::handle_event(app, event.state());
                })
                .build(),
        )
        .manage(commands::head_track::HeadTrackState::default())
        .manage(commands::stt_ondevice::OnDeviceSttState::default())
        .setup(|app| {
            // Register the capture hotkey once the app is up. Surface (don't
            // swallow with `?`) a registration failure: macOS can refuse a global
            // hotkey silently, and a swallowed error here looks like "nothing
            // happens on press" with no clue why.
            use tauri_plugin_global_shortcut::GlobalShortcutExt;
            let shortcut = commands::hotkey::capture_shortcut();
            match app.global_shortcut().register(shortcut) {
                Ok(()) => eprintln!("handsoff: registered capture hotkey {shortcut:?}"),
                Err(error) => eprintln!("handsoff: FAILED to register capture hotkey: {error}"),
            }
            // Overlay-as-UI: the transparent supervisor HUD is the only visible
            // window. The `main` window starts hidden (visible:false) and runs the
            // engine (camera/trackers/voice/CUA) headless, streaming to the overlay.
            // Show the overlay from the host at startup so the UI is up immediately,
            // independent of how fast the engine webview boots.
            match commands::overlay::show_overlay(app.handle().clone()) {
                Ok(()) => eprintln!("handsoff: overlay shown on startup"),
                Err(error) => eprintln!("handsoff: FAILED to show overlay on startup: {error}"),
            }
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            commands::readiness::readiness_probe,
            commands::storage::load_local_config,
            commands::storage::update_local_config,
            commands::storage::reset_local_config,
            commands::intent::intent_resolve,
            commands::cua_brain::cua_brain_step,
            commands::stt::stt_mint_token,
            commands::head_track::head_track_start,
            commands::head_track::head_track_stop,
            commands::head_track::head_track_recenter,
            commands::stt_ondevice::stt_ondevice_start,
            commands::stt_ondevice::stt_ondevice_stop,
            commands::cua::cua_permissions,
            commands::cua::cua_list_windows,
            commands::cua::cua_get_window_state,
            commands::cua::cua_launch_app,
            commands::cua::cua_click,
            commands::cua::cua_type_text,
            commands::cua::cua_set_value,
            commands::cua::cua_press_key,
            commands::cua::cua_hotkey,
            commands::cua::cua_scroll,
            commands::cua::cua_click_point,
            commands::permissions::request_media_permissions,
            commands::permissions::request_screen_recording,
            commands::permissions::restart_app,
            commands::permissions::open_privacy_settings,
            commands::overlay::show_overlay,
            commands::overlay::hide_overlay
        ])
        .run(tauri::generate_context!())
        .expect("error while running the HandsOff application");
}
