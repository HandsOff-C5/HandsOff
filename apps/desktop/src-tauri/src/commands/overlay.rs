// Full-screen pointing overlay window (#25 cursor seam). A transparent,
// borderless, always-on-top, click-through window over the real desktop that
// draws where the user is pointing — so the dot tracks on the actual screen, not
// just inside the camera preview. Created lazily on first show and reused.
//
// The window loads the same frontend bundle; `App` routes on the window label
// ("overlay") to render the bare pointing layer instead of the dashboard.

use tauri::{AppHandle, Manager, WebviewUrl, WebviewWindowBuilder};

const OVERLAY_LABEL: &str = "overlay";

#[cfg(target_os = "macos")]
fn position_over_primary_screen(window: &tauri::WebviewWindow) {
    if let Ok(Some(monitor)) = window.primary_monitor() {
        let size = monitor.size();
        let position = monitor.position();
        let _ = window.set_position(tauri::PhysicalPosition::new(position.x, position.y));
        let _ = window.set_size(tauri::PhysicalSize::new(size.width, size.height));
    }
}

#[cfg(not(target_os = "macos"))]
fn position_over_primary_screen(_window: &tauri::WebviewWindow) {}

/// Show the pointing overlay over the desktop, creating it the first time.
#[tauri::command]
pub fn show_overlay(app: AppHandle) -> Result<(), String> {
    if let Some(window) = app.get_webview_window(OVERLAY_LABEL) {
        position_over_primary_screen(&window);
        window.show().map_err(|e| e.to_string())?;
        let _ = window.set_ignore_cursor_events(true);
        return Ok(());
    }

    let window = WebviewWindowBuilder::new(&app, OVERLAY_LABEL, WebviewUrl::App("index.html".into()))
        .title("HandsOff overlay")
        .transparent(true)
        .decorations(false)
        .always_on_top(true)
        .skip_taskbar(true)
        .shadow(false)
        .focused(false)
        .visible(false)
        .build()
        .map_err(|e| e.to_string())?;

    position_over_primary_screen(&window);
    // Clicks pass straight through to whatever is underneath.
    window.set_ignore_cursor_events(true).map_err(|e| e.to_string())?;
    window.show().map_err(|e| e.to_string())?;
    Ok(())
}

/// Hide the pointing overlay.
#[tauri::command]
pub fn hide_overlay(app: AppHandle) -> Result<(), String> {
    if let Some(window) = app.get_webview_window(OVERLAY_LABEL) {
        window.hide().map_err(|e| e.to_string())?;
    }
    Ok(())
}
