// Full-screen pointing overlay window (#25 cursor seam). A transparent,
// borderless, always-on-top, click-through window over the real desktop that
// draws where the user is pointing — so the dot tracks on the actual screen, not
// just inside the camera preview. Created lazily on first show and reused.
//
// The window loads the same frontend bundle; `App` routes on the window label
// ("overlay") to render the bare pointing layer instead of the dashboard.

use tauri::{AppHandle, Manager, WebviewUrl, WebviewWindowBuilder};

const OVERLAY_LABEL: &str = "overlay";

// A screen rectangle in physical pixels: top-left (x, y) + size (w, h).
type Rect = (i32, i32, u32, u32);

// The bounding box that covers every monitor, so one overlay window spans the
// whole multi-monitor desktop. Pure so the geometry is unit-tested without a
// display. Empty input → a zero rect (the caller falls back to the primary).
fn union_bounds(monitors: &[Rect]) -> Rect {
    let Some(&(fx, fy, fw, fh)) = monitors.first() else {
        return (0, 0, 0, 0);
    };
    let mut min_x = fx;
    let mut min_y = fy;
    let mut max_x = fx + fw as i32;
    let mut max_y = fy + fh as i32;
    for &(x, y, w, h) in monitors.iter().skip(1) {
        min_x = min_x.min(x);
        min_y = min_y.min(y);
        max_x = max_x.max(x + w as i32);
        max_y = max_y.max(y + h as i32);
    }
    (min_x, min_y, (max_x - min_x) as u32, (max_y - min_y) as u32)
}

// Size + place the overlay so it covers EVERY display (the union of all monitor
// bounds), falling back to the primary if the monitor list is unavailable.
#[cfg(target_os = "macos")]
fn position_over_all_screens(window: &tauri::WebviewWindow) {
    let rects: Vec<Rect> = window
        .available_monitors()
        .map(|monitors| {
            monitors
                .iter()
                .map(|m| {
                    let p = m.position();
                    let s = m.size();
                    (p.x, p.y, s.width, s.height)
                })
                .collect()
        })
        .unwrap_or_default();

    let (x, y, w, h) = union_bounds(&rects);
    if w > 0 && h > 0 {
        let _ = window.set_position(tauri::PhysicalPosition::new(x, y));
        let _ = window.set_size(tauri::PhysicalSize::new(w, h));
        return;
    }
    if let Ok(Some(monitor)) = window.primary_monitor() {
        let _ = window.set_position(*monitor.position());
        let _ = window.set_size(*monitor.size());
    }
}

#[cfg(not(target_os = "macos"))]
fn position_over_all_screens(_window: &tauri::WebviewWindow) {}

/// Show the pointing overlay over the desktop, creating it the first time.
#[tauri::command]
pub fn show_overlay(app: AppHandle) -> Result<(), String> {
    if let Some(window) = app.get_webview_window(OVERLAY_LABEL) {
        position_over_all_screens(&window);
        window.show().map_err(|e| e.to_string())?;
        let _ = window.set_ignore_cursor_events(true);
        return Ok(());
    }

    let window =
        WebviewWindowBuilder::new(&app, OVERLAY_LABEL, WebviewUrl::App("index.html".into()))
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

    position_over_all_screens(&window);
    // Clicks pass straight through to whatever is underneath.
    window
        .set_ignore_cursor_events(true)
        .map_err(|e| e.to_string())?;
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

#[cfg(test)]
mod tests {
    use super::{union_bounds, Rect};

    #[test]
    fn union_of_a_single_monitor_is_itself() {
        assert_eq!(union_bounds(&[(0, 0, 1728, 1117)]), (0, 0, 1728, 1117));
    }

    #[test]
    fn union_spans_side_by_side_monitors() {
        // Primary at origin + a second display to its right.
        let monitors: Vec<Rect> = vec![(0, 0, 1728, 1117), (1728, 0, 2560, 1440)];
        assert_eq!(union_bounds(&monitors), (0, 0, 1728 + 2560, 1440));
    }

    #[test]
    fn union_covers_monitors_in_negative_space() {
        // A display left-of and above the primary (negative origin).
        let monitors: Vec<Rect> = vec![(0, 0, 1000, 1000), (-800, -200, 800, 600)];
        assert_eq!(union_bounds(&monitors), (-800, -200, 1800, 1200));
    }

    #[test]
    fn union_of_no_monitors_is_zero() {
        assert_eq!(union_bounds(&[]), (0, 0, 0, 0));
    }
}
