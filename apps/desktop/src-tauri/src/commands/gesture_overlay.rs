// Gesture-overlay sidecar bridge. The sidecar (`binaries/gesture-overlay`) owns one
// transparent, click-through, `.screenSaver`-level window per display and draws the hand-
// gesture cursor dots + the calibration target ring directly over the real desktop — so the
// cursor is a separate pointer that can travel across ALL connected monitors (ported from the
// funstuff GestureControlOverlay architecture). This host owns the sidecar's lifetime and
// drives it with a tiny line protocol on stdin; the sidecar reports its CoreGraphics display
// layout on stdout so calibration targets and the drawn dot share one coordinate space.

use std::sync::{Arc, Mutex};
use tauri::{AppHandle, State};
use tauri_plugin_shell::{
    process::{CommandChild, CommandEvent},
    ShellExt,
};

const SIDECAR_NAME: &str = "gesture-overlay";

// One display in CoreGraphics global coordinates (top-left origin; secondary displays may be
// negative). Mirrors the sidecar's `displays` payload and the contracts SurfaceBounds space,
// so the frontend can lay out a per-display calibration grid and build display surfaces
// without any further conversion.
#[derive(Debug, Clone, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DisplayInfo {
    pub id: String,
    pub is_main: bool,
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
}

#[derive(Debug, serde::Deserialize)]
struct OverlayDisplay {
    id: String,
    #[serde(rename = "isMain")]
    is_main: bool,
    x: f64,
    y: f64,
    width: f64,
    height: f64,
}

#[derive(Debug, serde::Deserialize)]
struct DisplaysPayload {
    displays: Vec<OverlayDisplay>,
}

#[derive(Clone, Default)]
pub struct GestureOverlayState {
    child: Arc<Mutex<Option<CommandChild>>>,
    generation: Arc<Mutex<u64>>,
    stdout_buffer: Arc<Mutex<String>>,
    displays: Arc<Mutex<Vec<DisplayInfo>>>,
}

/// Start the overlay sidecar. It emits its display layout on stdout once at launch; we wait
/// for that first line so callers can point immediately after. Returns the display list so the
/// frontend can build a calibration grid in the same call. Restarting kills any prior sidecar.
#[tauri::command]
pub async fn gesture_overlay_start(
    app: AppHandle,
    state: State<'_, GestureOverlayState>,
) -> Result<Vec<DisplayInfo>, String> {
    stop_child(&state);
    state
        .displays
        .lock()
        .expect("gesture-overlay displays lock poisoned")
        .clear();
    state
        .stdout_buffer
        .lock()
        .expect("gesture-overlay stdout buffer lock poisoned")
        .clear();

    let (mut rx, child) = app
        .shell()
        .sidecar(SIDECAR_NAME)
        .map_err(|error| format!("gesture-overlay sidecar unavailable: {error}"))?
        .spawn()
        .map_err(|error| format!("gesture-overlay sidecar failed to start: {error}"))?;

    let generation = next_generation(&state);
    *state
        .child
        .lock()
        .expect("gesture-overlay child lock poisoned") = Some(child);

    // Wait for the sidecar's launch-time display report before declaring the overlay ready.
    // The sidecar prints anything spurious before that line; once we have it, hand the stream
    // to a background drainer and cache the layout for `list_displays`.
    let displays = loop {
        match rx.recv().await {
            Some(event) => match event {
                CommandEvent::Stdout(chunk) => {
                    let mut buffer = state
                        .stdout_buffer
                        .lock()
                        .expect("gesture-overlay stdout buffer lock poisoned");
                    buffer.push_str(&String::from_utf8_lossy(&chunk));
                    let mut found: Option<Vec<DisplayInfo>> = None;
                    while let Some(idx) = buffer.find('\n') {
                        let line: String = buffer.drain(..=idx).collect();
                        if found.is_none() {
                            found = parse_displays(&line);
                        }
                    }
                    if let Some(parsed) = found {
                        break parsed;
                    }
                }
                CommandEvent::Stderr(line) => eprintln!(
                    "[handsoff gesture-overlay] stderr: {}",
                    String::from_utf8_lossy(&line)
                ),
                CommandEvent::Error(error) => {
                    return Err(format!("gesture-overlay stream error: {error}"))
                }
                CommandEvent::Terminated(_) => {
                    return Err("gesture-overlay sidecar exited before reporting displays".into())
                }
                _ => {}
            },
            None => return Err("gesture-overlay sidecar stream closed before displays".into()),
        }
    };

    let state_handle = state.inner().clone();
    tauri::async_runtime::spawn(async move {
        while let Some(event) = rx.recv().await {
            drain_sidecar_event(&state_handle, event);
        }
        clear_child_if_current(&state_handle, generation);
    });

    *state
        .displays
        .lock()
        .expect("gesture-overlay displays lock poisoned") = displays.clone();

    Ok(displays)
}

/// Stop the overlay sidecar (closes stdin; the sidecar quits on EOF).
#[tauri::command]
pub async fn gesture_overlay_stop(state: State<'_, GestureOverlayState>) -> Result<(), String> {
    stop_child(&state);
    state
        .displays
        .lock()
        .expect("gesture-overlay displays lock poisoned")
        .clear();
    Ok(())
}

/// Move a named cursor (`"main"`, `"left"`, `"right"`) to a global screen point.
#[tauri::command]
pub fn gesture_overlay_move(
    state: State<'_, GestureOverlayState>,
    cursor_id: String,
    x: f64,
    y: f64,
) -> Result<(), String> {
    // Whole pixels match what the eye can resolve and keep the line short; negative coords
    // (a cursor on a display left/above the primary) are valid.
    write_line(&state, format!("MOVE {cursor_id} {} {}", px(x), px(y)))
}

/// Show the calibration target ring at a global screen point.
#[tauri::command]
pub fn gesture_overlay_target(
    state: State<'_, GestureOverlayState>,
    x: f64,
    y: f64,
) -> Result<(), String> {
    write_line(&state, format!("TARGET {} {}", px(x), px(y)))
}

/// Remove the calibration target ring.
#[tauri::command]
pub fn gesture_overlay_untarget(state: State<'_, GestureOverlayState>) -> Result<(), String> {
    write_line(&state, "UNTARGET".to_string())
}

/// Clear one cursor (by id) or, with no id, every cursor + the target.
#[tauri::command]
pub fn gesture_overlay_clear(
    state: State<'_, GestureOverlayState>,
    cursor_id: Option<String>,
) -> Result<(), String> {
    match cursor_id {
        Some(id) => write_line(&state, format!("CLEAR {id}")),
        None => write_line(&state, "CLEAR".to_string()),
    }
}

/// The cached display layout reported by the sidecar at launch. Empty until the overlay has
/// been started, so callers always start the overlay before requesting the layout.
#[tauri::command]
pub fn list_displays(state: State<'_, GestureOverlayState>) -> Result<Vec<DisplayInfo>, String> {
    Ok(state
        .displays
        .lock()
        .expect("gesture-overlay displays lock poisoned")
        .clone())
}

fn px(value: f64) -> i64 {
    value.round() as i64
}

fn write_line(state: &GestureOverlayState, line: String) -> Result<(), String> {
    let mut guard = state
        .child
        .lock()
        .expect("gesture-overlay child lock poisoned");
    let child = guard
        .as_mut()
        .ok_or_else(|| "gesture-overlay sidecar not running".to_string())?;
    let mut bytes = line.into_bytes();
    bytes.push(b'\n');
    child
        .write(&bytes)
        .map_err(|error| format!("gesture-overlay write failed: {error}"))
}

fn stop_child(state: &GestureOverlayState) {
    if let Some(child) = state
        .child
        .lock()
        .expect("gesture-overlay child lock poisoned")
        .take()
    {
        let _ = child.kill();
    }
}

fn next_generation(state: &GestureOverlayState) -> u64 {
    let mut generation = state
        .generation
        .lock()
        .expect("gesture-overlay generation lock poisoned");
    *generation += 1;
    *generation
}

fn clear_child_if_current(state: &GestureOverlayState, finished_generation: u64) {
    let current = *state
        .generation
        .lock()
        .expect("gesture-overlay generation lock poisoned");
    if finished_generation == current {
        *state
            .child
            .lock()
            .expect("gesture-overlay child lock poisoned") = None;
    }
}

fn drain_sidecar_event(state: &GestureOverlayState, event: CommandEvent) {
    if let CommandEvent::Stdout(chunk) = event {
        let mut buffer = state
            .stdout_buffer
            .lock()
            .expect("gesture-overlay stdout buffer lock poisoned");
        buffer.push_str(&String::from_utf8_lossy(&chunk));
        // The sidecar only speaks on stdout at launch (handled inline in start). Drain any
        // later lines so the buffer cannot grow without bound.
        while buffer.contains('\n') {
            if let Some(idx) = buffer.find('\n') {
                buffer.drain(..=idx);
            }
        }
    }
}

fn parse_displays(line: &str) -> Option<Vec<DisplayInfo>> {
    let payload: DisplaysPayload = serde_json::from_str(line.trim()).ok()?;
    Some(
        payload
            .displays
            .into_iter()
            .map(|d| DisplayInfo {
                id: d.id,
                is_main: d.is_main,
                x: d.x,
                y: d.y,
                width: d.width,
                height: d.height,
            })
            .collect(),
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn px_rounds_to_nearest_integer() {
        assert_eq!(px(12.6), 13);
        assert_eq!(px(-1191.4), -1191);
    }

    #[test]
    fn parses_overlay_display_line() {
        let line = r#"{"kind":"displays","displays":[{"id":"1","isMain":true,"x":0,"y":0,"width":1512,"height":982},{"id":"2","isMain":false,"x":-1191,"y":-1080,"width":1920,"height":1080}]}"#;
        let parsed = parse_displays(line).expect("should parse the sidecar displays line");
        assert_eq!(parsed.len(), 2);
        assert!(parsed[0].is_main);
        assert_eq!(parsed[0].id, "1");
        assert_eq!(parsed[1].x, -1191.0);
        assert_eq!(parsed[1].y, -1080.0);
    }

    #[test]
    fn ignores_non_displays_lines() {
        assert!(parse_displays(r#"{"kind":"selftest","displays":3}"#).is_none());
        assert!(parse_displays("not json").is_none());
    }

    #[test]
    fn writes_require_a_running_sidecar() {
        let state = GestureOverlayState::default();
        assert_eq!(
            write_line(&state, "MOVE main 10 10".to_string()).unwrap_err(),
            "gesture-overlay sidecar not running"
        );
    }
}
