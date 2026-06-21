// HandsOff desktop shell entry point.
//
// Opens the mission-control dashboard window and wires the commands the frontend
// invokes. Readiness reports host capability state; storage keeps non-secret
// local preferences for settings. CUA command placeholders stay un-declared
// until their owning lane (#19) lands.
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

mod commands;

fn main() {
    tauri::Builder::default()
        .plugin(tauri_plugin_shell::init())
        .manage(commands::stt_ondevice::OnDeviceSttState::default())
        .invoke_handler(tauri::generate_handler![
            commands::readiness::readiness_probe,
            commands::storage::load_local_config,
            commands::storage::update_local_config,
            commands::storage::reset_local_config,
            commands::stt::stt_mint_token,
            commands::stt_ondevice::stt_ondevice_start,
            commands::stt_ondevice::stt_ondevice_stop
        ])
        .run(tauri::generate_context!())
        .expect("error while running the HandsOff application");
}
