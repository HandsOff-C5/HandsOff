// HandsOff desktop shell entry point.
//
// Opens the mission-control dashboard window and wires the commands the frontend
// invokes. The readiness probe (issue #17) is the first; the `cua` and `storage`
// command placeholders stay un-declared until their owning lanes (#16/#19) land.
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

mod commands;

fn main() {
    tauri::Builder::default()
        .invoke_handler(tauri::generate_handler![
            commands::readiness::readiness_probe
        ])
        .run(tauri::generate_context!())
        .expect("error while running the HandsOff application");
}
