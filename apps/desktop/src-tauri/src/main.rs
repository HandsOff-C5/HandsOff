// HandsOff desktop shell entry point.
//
// Opens the home-dashboard dashboard window and wires the commands the frontend
// invokes. Readiness reports host capability state; storage keeps non-secret
// local preferences for settings. CUA exposes a typed unavailable state until
// the live driver transport lands.
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

mod commands;

fn main() {
    tauri::Builder::default()
        .plugin(tauri_plugin_shell::init())
        // L0: the Home Dashboard (`main`) hides instead of closing — closing its
        // window must never destroy it or kill the engine/bridge under it. The
        // menu-bar `openHome` command (G1) re-shows it; other windows close normally.
        .on_window_event(|window, event| {
            if let tauri::WindowEvent::CloseRequested { api, .. } = event {
                match commands::lifecycle::window_close_action(window.label()) {
                    commands::lifecycle::WindowCloseAction::HideAndKeepAlive => {
                        api.prevent_close();
                        let _ = window.hide();
                    }
                    commands::lifecycle::WindowCloseAction::AllowClose => {}
                }
            }
        })
        .manage(commands::head_track::HeadTrackState::default())
        .manage(commands::gesture_overlay::GestureOverlayState::default())
        .manage(commands::stt_ondevice::OnDeviceSttState::default())
        .manage(commands::observability::ObservabilitySink::default())
        .setup(|app| {
            // L0: Director is menu-bar-first — run as an accessory app so there is
            // no Dock icon (the menu-bar item is the presence). The Home Dashboard
            // still shows; it just no longer owns a Dock tile.
            #[cfg(target_os = "macos")]
            app.set_activation_policy(tauri::ActivationPolicy::Accessory);
            // Director engine bridge — loopback WS server for the native Swift sidecar (G0).
            tauri::async_runtime::spawn(commands::bridge::serve());
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
            commands::cua::cua_driver_call,
            commands::cua::cua_driver_tools,
            commands::permissions::request_media_permissions,
            commands::permissions::request_screen_recording,
            commands::permissions::restart_app,
            commands::permissions::open_privacy_settings,
            commands::overlay::show_overlay,
            commands::overlay::hide_overlay,
            commands::observability::observability_emit,
            commands::observability::observability_records,
            commands::observability::observability_export_policy
        ])
        .build(tauri::generate_context!())
        .expect("error while building the HandsOff application")
        // L0: own the run loop so the engine survives a last-window close. `code` is
        // `None` for an OS/last-window-close exit (keep the menu-bar-first engine and
        // its loopback bridge alive) and `Some` for a programmatic `exit`/`restart`
        // (e.g. the `restart_app` command) — those are allowed through.
        .run(|_app_handle, event| {
            if let tauri::RunEvent::ExitRequested { code, api, .. } = event {
                if commands::lifecycle::should_prevent_exit(code) {
                    api.prevent_exit();
                }
            }
        });
}
