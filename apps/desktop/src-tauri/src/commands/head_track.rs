use serde::{Deserialize, Serialize};
use serde_json::json;
use std::process::Command;
use std::sync::{Arc, Mutex};
use std::time::{SystemTime, UNIX_EPOCH};
use tauri::{AppHandle, Emitter, State};
use tauri_plugin_shell::{
    process::{CommandChild, CommandEvent},
    ShellExt,
};

const EVENT_NAME: &str = "stt://head";
const SIDECAR_NAME: &str = "head-track";
const DEFAULT_RADIUS: f64 = 240.0;

#[derive(Clone, Default)]
pub struct HeadTrackState {
    child: Arc<Mutex<Option<CommandChild>>>,
    latest_point: Arc<Mutex<Option<HeadPoint>>>,
    stdout_buffer: Arc<Mutex<String>>,
}

#[derive(Debug, Clone, Copy, Deserialize, Serialize)]
struct HeadPoint {
    x: f64,
    y: f64,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(tag = "kind")]
#[serde(deny_unknown_fields)]
enum HeadSidecarEvent {
    #[serde(rename = "start")]
    Start { ts: u64 },
    #[serde(rename = "point")]
    Point {
        x: f64,
        y: f64,
        yaw: Option<f64>,
        pitch: Option<f64>,
        confidence: f64,
        ts: u64,
    },
    #[serde(rename = "stop")]
    Stop { ts: u64 },
    #[serde(rename = "error")]
    Error { message: String, ts: u64 },
}

#[derive(Debug, Clone, Deserialize)]
struct DriverWindowList {
    windows: Vec<DriverWindow>,
}

#[derive(Debug, Clone, Deserialize)]
struct DriverWindow {
    app_name: String,
    title: String,
    pid: u32,
    window_id: u32,
    is_on_screen: bool,
    z_index: i64,
    bounds: Option<WindowBounds>,
}

#[derive(Debug, Clone, Copy, Deserialize)]
struct WindowBounds {
    x: f64,
    y: f64,
    width: f64,
    height: f64,
}

#[derive(Debug, Clone)]
struct AttentionWindow {
    surface: SurfaceSnapshot,
    bounds: WindowBounds,
    z_index: i64,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
struct SurfaceSnapshot {
    id: String,
    title: String,
    app: String,
    pid: Option<u32>,
    window_id: Option<u32>,
    availability: &'static str,
    access_status: &'static str,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
struct AttentionCandidate {
    surface: SurfaceSnapshot,
    score: f64,
    distance: f64,
}

#[derive(Debug, Clone)]
struct RankedCandidate {
    candidate: AttentionCandidate,
    z_index: i64,
}

#[tauri::command]
pub async fn head_track_start(
    app: AppHandle,
    state: State<'_, HeadTrackState>,
) -> Result<(), String> {
    stop_child(&state)?;
    *state
        .latest_point
        .lock()
        .expect("head-track point lock poisoned") = None;
    state
        .stdout_buffer
        .lock()
        .expect("head-track stdout buffer lock poisoned")
        .clear();

    let (mut rx, child) = app
        .shell()
        .sidecar(SIDECAR_NAME)
        .map_err(|error| format!("head-track sidecar unavailable: {error}"))?
        .spawn()
        .map_err(|error| format!("head-track sidecar failed to start: {error}"))?;

    *state.child.lock().expect("head-track child lock poisoned") = Some(child);

    let app_handle = app.clone();
    let state_handle = state.inner().clone();
    tauri::async_runtime::spawn(async move {
        while let Some(event) = rx.recv().await {
            handle_sidecar_event(&app_handle, &state_handle, event);
        }
        *state_handle
            .child
            .lock()
            .expect("head-track child lock poisoned") = None;
    });

    Ok(())
}

#[tauri::command]
pub fn head_track_stop(state: State<'_, HeadTrackState>) -> Result<(), String> {
    stop_child(&state)
}

fn stop_child(state: &HeadTrackState) -> Result<(), String> {
    let child = state
        .child
        .lock()
        .expect("head-track child lock poisoned")
        .take();
    if let Some(child) = child {
        child
            .kill()
            .map_err(|error| format!("head-track sidecar failed to stop: {error}"))?;
    }
    Ok(())
}

fn handle_sidecar_event(app: &AppHandle, state: &HeadTrackState, event: CommandEvent) {
    match event {
        CommandEvent::Stdout(chunk) => {
            let lines = {
                let mut buffer = state
                    .stdout_buffer
                    .lock()
                    .expect("head-track stdout buffer lock poisoned");
                match take_stdout_lines(&mut buffer, &chunk) {
                    Ok(lines) => lines,
                    Err(message) => {
                        buffer.clear();
                        emit_error(app, message);
                        return;
                    }
                }
            };
            for line in lines {
                handle_head_event_line(app, state, &line);
            }
        }
        CommandEvent::Stderr(line) => emit_error(
            app,
            format!("head-track stderr: {}", String::from_utf8_lossy(&line)),
        ),
        CommandEvent::Error(error) => emit_error(app, format!("head-track stream error: {error}")),
        CommandEvent::Terminated(_payload) => {}
        _ => {}
    }
}

fn handle_head_event_line(app: &AppHandle, state: &HeadTrackState, line: &str) {
    match parse_head_event(line) {
        Ok(event) => {
            if let HeadSidecarEvent::Point { x, y, .. } = event {
                *state
                    .latest_point
                    .lock()
                    .expect("head-track point lock poisoned") = Some(HeadPoint { x, y });
            }
            let _ = app.emit(EVENT_NAME, &event);
            if let HeadSidecarEvent::Stop { ts } = event {
                emit_candidates_for_latest_point(app, state, ts);
            }
        }
        Err(message) => emit_error(app, format!("invalid head-track event: {message}")),
    }
}

fn take_stdout_lines(buffer: &mut String, chunk: &[u8]) -> Result<Vec<String>, String> {
    let text = std::str::from_utf8(chunk)
        .map_err(|error| format!("head-track stdout was not UTF-8: {error}"))?;
    buffer.push_str(text);

    let mut lines = Vec::new();
    while let Some(newline) = buffer.find('\n') {
        let line = buffer.drain(..=newline).collect::<String>();
        let trimmed = line.trim();
        if !trimmed.is_empty() {
            lines.push(trimmed.to_string());
        }
    }
    Ok(lines)
}

fn emit_candidates_for_latest_point(app: &AppHandle, state: &HeadTrackState, ts: u64) {
    let point = *state
        .latest_point
        .lock()
        .expect("head-track point lock poisoned");
    let Some(point) = point else {
        return;
    };
    match cua_attention_windows() {
        Ok(windows) => {
            let candidates = rank_attention_candidates(point, &windows, DEFAULT_RADIUS);
            let _ = app.emit(
                EVENT_NAME,
                json!({
                    "kind": "candidates",
                    "point": point,
                    "candidates": candidates,
                    "ts": ts
                }),
            );
        }
        Err(message) => emit_error(app, message),
    }
}

fn emit_error(app: &AppHandle, message: String) {
    let _ = app.emit(
        EVENT_NAME,
        json!({
            "kind": "error",
            "message": message,
            "ts": now_ms()
        }),
    );
}

fn parse_head_event(line: &str) -> Result<HeadSidecarEvent, String> {
    let event: HeadSidecarEvent =
        serde_json::from_str(line).map_err(|error| format!("could not parse JSON: {error}"))?;
    validate_head_event(&event)?;
    Ok(event)
}

fn validate_head_event(event: &HeadSidecarEvent) -> Result<(), String> {
    match event {
        HeadSidecarEvent::Point {
            x,
            y,
            yaw,
            pitch,
            confidence,
            ..
        } => {
            if !x.is_finite() || !y.is_finite() {
                return Err("point coordinates must be finite".to_string());
            }
            if yaw.is_some_and(|value| !value.is_finite())
                || pitch.is_some_and(|value| !value.is_finite())
            {
                return Err("pose values must be finite or null".to_string());
            }
            if !(0.0..=1.0).contains(confidence) {
                return Err("confidence must be between 0 and 1".to_string());
            }
        }
        HeadSidecarEvent::Error { message, .. } if message.trim().is_empty() => {
            return Err("error message must not be empty".to_string());
        }
        _ => {}
    }
    Ok(())
}

fn cua_attention_windows() -> Result<Vec<AttentionWindow>, String> {
    let output = Command::new("cua-driver")
        .args(["call", "list_windows", r#"{"on_screen_only":true}"#])
        .output()
        .map_err(|error| format!("cua-driver failed to start: {error}"))?;
    if !output.status.success() {
        return Err(format!(
            "cua-driver failed: {}",
            String::from_utf8_lossy(&output.stderr)
        ));
    }
    let list: DriverWindowList = serde_json::from_slice(&output.stdout)
        .map_err(|error| format!("Could not parse CUA windows: {error}"))?;
    Ok(list
        .windows
        .into_iter()
        .filter_map(attention_window_from_driver)
        .collect())
}

fn attention_window_from_driver(window: DriverWindow) -> Option<AttentionWindow> {
    let bounds = window.bounds?;
    if window.app_name.to_ascii_lowercase().contains("cua driver") {
        return None;
    }
    Some(AttentionWindow {
        surface: SurfaceSnapshot {
            id: format!("{}:{}", window.pid, window.window_id),
            title: if window.title.is_empty() {
                window.app_name.clone()
            } else {
                window.title
            },
            app: window.app_name,
            pid: Some(window.pid),
            window_id: Some(window.window_id),
            availability: if window.is_on_screen {
                "available"
            } else {
                "unknown"
            },
            access_status: "accessible",
        },
        bounds,
        z_index: window.z_index,
    })
}

fn rank_attention_candidates(
    point: HeadPoint,
    windows: &[AttentionWindow],
    radius: f64,
) -> Vec<AttentionCandidate> {
    if radius <= 0.0 {
        return vec![];
    }
    let mut ranked = windows
        .iter()
        .filter(|window| is_rankable(window))
        .filter_map(|window| {
            let distance = round3(distance_to_bounds(point, window.bounds));
            if distance > radius {
                return None;
            }
            Some(RankedCandidate {
                candidate: AttentionCandidate {
                    surface: window.surface.clone(),
                    score: round3(1.0 - distance / radius),
                    distance,
                },
                z_index: window.z_index,
            })
        })
        .collect::<Vec<_>>();

    ranked.sort_by(|a, b| {
        b.candidate
            .score
            .total_cmp(&a.candidate.score)
            .then_with(|| a.candidate.distance.total_cmp(&b.candidate.distance))
            .then_with(|| b.z_index.cmp(&a.z_index))
            .then_with(|| a.candidate.surface.id.cmp(&b.candidate.surface.id))
    });

    ranked.into_iter().map(|ranked| ranked.candidate).collect()
}

fn is_rankable(window: &AttentionWindow) -> bool {
    window.surface.availability == "available"
        && window.surface.access_status == "accessible"
        && window.bounds.width > 0.0
        && window.bounds.height > 0.0
}

fn distance_to_bounds(point: HeadPoint, bounds: WindowBounds) -> f64 {
    let nearest_x = clamp(point.x, bounds.x, bounds.x + bounds.width);
    let nearest_y = clamp(point.y, bounds.y, bounds.y + bounds.height);
    (point.x - nearest_x).hypot(point.y - nearest_y)
}

fn clamp(value: f64, min: f64, max: f64) -> f64 {
    value.min(max).max(min)
}

fn round3(value: f64) -> f64 {
    (value * 1000.0).round() / 1000.0
}

fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_millis() as u64)
        .unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn surface(id: &str) -> SurfaceSnapshot {
        SurfaceSnapshot {
            id: id.to_string(),
            title: id.to_string(),
            app: "Codex".to_string(),
            pid: Some(42),
            window_id: Some(7),
            availability: "available",
            access_status: "accessible",
        }
    }

    fn window(id: &str, bounds: WindowBounds, z_index: i64) -> AttentionWindow {
        AttentionWindow {
            surface: surface(id),
            bounds,
            z_index,
        }
    }

    #[test]
    fn parses_valid_head_point_event() {
        let event = parse_head_event(
            r#"{"kind":"point","x":10,"y":20,"yaw":null,"pitch":0.1,"confidence":0.9,"ts":1803000000001}"#,
        )
        .expect("head point should parse");

        assert!(matches!(
            event,
            HeadSidecarEvent::Point {
                x: 10.0,
                y: 20.0,
                confidence: 0.9,
                ..
            }
        ));
    }

    #[test]
    fn rejects_malformed_head_events_loudly() {
        assert!(parse_head_event("not-json").is_err());
        assert!(parse_head_event(
            r#"{"kind":"point","x":10,"y":20,"yaw":null,"pitch":null,"confidence":1.2,"ts":1}"#,
        )
        .is_err());
        assert!(parse_head_event(r#"{"kind":"stop","ts":1,"extra":true}"#).is_err());
    }

    #[test]
    fn buffers_split_newline_delimited_head_events() {
        let mut buffer = String::new();
        assert!(
            take_stdout_lines(&mut buffer, br#"{"kind":"start","ts":1}"#)
                .expect("partial line should buffer")
                .is_empty()
        );

        let lines = take_stdout_lines(&mut buffer, b"\n").expect("newline should flush one line");

        assert_eq!(lines, vec![r#"{"kind":"start","ts":1}"#]);
        assert!(buffer.is_empty());
    }

    #[test]
    fn handles_coalesced_newline_delimited_head_events() {
        let mut buffer = String::new();
        let lines = take_stdout_lines(
            &mut buffer,
            br#"{"kind":"start","ts":1}
{"kind":"stop","ts":2}
"#,
        )
        .expect("coalesced lines should parse");

        assert_eq!(
            lines,
            vec![r#"{"kind":"start","ts":1}"#, r#"{"kind":"stop","ts":2}"#]
        );
        assert!(buffer.is_empty());
    }

    #[test]
    fn ignores_blank_stdout_lines_and_rejects_invalid_utf8() {
        let mut buffer = String::new();
        assert!(take_stdout_lines(&mut buffer, b"\n\n")
            .expect("blank lines are valid framing")
            .is_empty());
        assert!(take_stdout_lines(&mut buffer, &[0xff]).is_err());
    }

    #[test]
    fn ranks_accessible_windows_by_distance_then_z_index() {
        let candidates = rank_attention_candidates(
            HeadPoint { x: 100.0, y: 100.0 },
            &[
                window(
                    "a:1",
                    WindowBounds {
                        x: 0.0,
                        y: 200.0,
                        width: 100.0,
                        height: 100.0,
                    },
                    1,
                ),
                window(
                    "b:2",
                    WindowBounds {
                        x: 200.0,
                        y: 0.0,
                        width: 100.0,
                        height: 100.0,
                    },
                    2,
                ),
                window(
                    "outside:3",
                    WindowBounds {
                        x: 251.0,
                        y: 0.0,
                        width: 100.0,
                        height: 100.0,
                    },
                    3,
                ),
            ],
            100.0,
        );

        assert_eq!(
            candidates
                .iter()
                .map(|candidate| candidate.surface.id.as_str())
                .collect::<Vec<_>>(),
            vec!["b:2", "a:1"]
        );
        assert_eq!(candidates[0].score, 0.0);
        assert_eq!(candidates[0].distance, 100.0);
    }

    #[test]
    fn returns_empty_candidates_when_no_window_is_in_the_neighborhood() {
        let candidates = rank_attention_candidates(
            HeadPoint { x: 0.0, y: 0.0 },
            &[window(
                "far:1",
                WindowBounds {
                    x: 500.0,
                    y: 500.0,
                    width: 100.0,
                    height: 100.0,
                },
                1,
            )],
            100.0,
        );

        assert!(candidates.is_empty());
    }

    #[test]
    fn maps_driver_windows_with_bounds_to_surface_candidates() {
        let window = attention_window_from_driver(DriverWindow {
            app_name: "Notes".to_string(),
            title: "".to_string(),
            pid: 42,
            window_id: 7,
            is_on_screen: true,
            z_index: 1,
            bounds: Some(WindowBounds {
                x: 0.0,
                y: 0.0,
                width: 100.0,
                height: 100.0,
            }),
        })
        .expect("window with bounds should map");

        assert_eq!(window.surface.id, "42:7");
        assert_eq!(window.surface.title, "Notes");
        assert_eq!(window.surface.access_status, "accessible");
    }
}
