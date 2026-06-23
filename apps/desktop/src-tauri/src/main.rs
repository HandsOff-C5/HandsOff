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
        .manage(commands::stt_ondevice::OnDeviceSttState::default())
        .setup(|app| {
            // Arm the Right Option + ? capture hotkey in the app process (#95).
            commands::hotkey::arm(app.handle().clone());
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            commands::readiness::readiness_probe,
            commands::storage::load_local_config,
            commands::storage::update_local_config,
            commands::storage::reset_local_config,
            commands::stt::stt_mint_token,
            commands::head_track::head_track_start,
            commands::head_track::head_track_stop,
            commands::stt_ondevice::stt_ondevice_start,
            commands::stt_ondevice::stt_ondevice_stop,
            commands::cua::cua_permissions,
            commands::cua::cua_list_windows,
            commands::cua::cua_get_window_state,
            commands::cua::cua_click,
            commands::cua::cua_type_text,
            commands::cua::cua_set_value,
            commands::permissions::request_media_permissions,
            commands::permissions::open_privacy_settings
        ])
        .run(tauri::generate_context!())
        .expect("error while running the HandsOff application");
}
