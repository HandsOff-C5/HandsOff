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
        .manage(commands::head_track::HeadTrackState::default())
        .manage(commands::gesture_overlay::GestureOverlayState::default())
        .manage(commands::stt_ondevice::OnDeviceSttState::default())
        .setup(|app| {
            // Capture trigger (#95): the bare `fn` (Globe) key, observed via a
            // listen-only CGEventTap. press-hold -> start/stop, double-tap ->
            // toggle. install() spawns its own thread and surfaces failures via
            // stderr (Accessibility not granted -> tap is NULL), since a swallowed
            // failure here looks like "nothing happens on fn" with no clue why.
            commands::hotkey::install(app.handle().clone());
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
            commands::gesture_overlay::gesture_overlay_start,
            commands::gesture_overlay::gesture_overlay_stop,
            commands::gesture_overlay::gesture_overlay_move,
            commands::gesture_overlay::gesture_overlay_target,
            commands::gesture_overlay::gesture_overlay_untarget,
            commands::gesture_overlay::gesture_overlay_clear,
            commands::gesture_overlay::list_displays,
            commands::stt_ondevice::stt_ondevice_start,
            commands::stt_ondevice::stt_ondevice_stop,
            commands::cua::cua_permissions,
            commands::cua::cua_list_apps,
            commands::cua::cua_list_windows,
            commands::cua::cua_get_window_state,
            commands::cua::cua_screenshot,
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
