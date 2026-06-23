// HandsOff desktop shell entry point.
//
// Opens the mission-control dashboard window and wires the commands the frontend
// invokes. Readiness reports host capability state; storage keeps non-secret
// local preferences for settings. CUA exposes a typed unavailable state until
// the live driver transport lands.
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

mod commands;

fn main() {
    tauri::Builder::default()
        .plugin(tauri_plugin_shell::init())
        // Capture hotkeys (#95) via the global-shortcut plugin — no
        // Accessibility/Input Monitoring permission needed. Command+Option+? is
        // hold-to-capture; Control+Shift+Space is tap-to-toggle.
        .plugin(
            tauri_plugin_global_shortcut::Builder::new()
                .with_handler(|app, shortcut, event| {
                    commands::hotkey::handle_event(app, shortcut, event.state());
                })
                .build(),
        )
        .manage(commands::head_track::HeadTrackState::default())
        .manage(commands::stt_ondevice::OnDeviceSttState::default())
        .setup(|app| {
            // Register capture hotkeys once the app is up. Surface (don't
            // swallow with `?`) a registration failure: macOS can refuse a global
            // hotkey silently, and a swallowed error here looks like "nothing
            // happens on press" with no clue why.
            use tauri_plugin_global_shortcut::GlobalShortcutExt;
            for shortcut in commands::hotkey::capture_shortcuts() {
                match app.global_shortcut().register(shortcut) {
                    Ok(()) => eprintln!("handsoff: registered capture hotkey {shortcut:?}"),
                    Err(error) => {
                        eprintln!(
                            "handsoff: FAILED to register capture hotkey {shortcut:?}: {error}"
                        )
                    }
                }
            }
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            commands::readiness::readiness_probe,
            commands::storage::load_local_config,
            commands::storage::update_local_config,
            commands::storage::reset_local_config,
            commands::intent::intent_resolve,
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
