// HandsOff desktop shell entry point.
//
// Scope (issue #15): open the mission-control dashboard window and load the
// web frontend. No CUA, readiness, or storage commands are wired here yet —
// those land with their owning issues (#40/#41/#48). The empty placeholder
// modules under `commands/` are intentionally left un-declared.
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

fn main() {
    tauri::Builder::default()
        .run(tauri::generate_context!())
        .expect("error while running the HandsOff application");
}
