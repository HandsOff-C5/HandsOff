mod candidates;
mod event;

use serde_json::json;
use std::sync::{Arc, Mutex};
use std::time::{SystemTime, UNIX_EPOCH};
use tauri::{AppHandle, Emitter, State};
use tauri_plugin_shell::{
    process::{CommandChild, CommandEvent},
    ShellExt,
};

use self::candidates::{cua_attention_windows, rank_attention_candidates, DEFAULT_RADIUS};
use self::event::{parse_head_event, take_stdout_lines, HeadPoint, HeadSidecarEvent};
use super::storage::HeadPointerConfig;

const EVENT_NAME: &str = "stt://head";
const SIDECAR_NAME: &str = "head-track";

#[derive(Clone, Default)]
pub struct HeadTrackState {
    child: Arc<Mutex<Option<CommandChild>>>,
    generation: Arc<Mutex<u64>>,
    latest_point: Arc<Mutex<Option<HeadPoint>>>,
    stdout_buffer: Arc<Mutex<String>>,
}

#[tauri::command]
pub async fn head_track_start(
    app: AppHandle,
    state: State<'_, HeadTrackState>,
    head_pointer: Option<HeadPointerConfig>,
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

    let mut child = child;
    if let Some(head_pointer) = head_pointer {
        let line = config_control_line(&head_pointer)?;
        if let Err(error) = child.write(&line) {
            let _ = child.kill();
            return Err(format!(
                "head-track sidecar failed to receive config: {error}"
            ));
        }
    }

    let generation = next_generation(&state);
    *state.child.lock().expect("head-track child lock poisoned") = Some(child);

    let app_handle = app.clone();
    let state_handle = state.inner().clone();
    tauri::async_runtime::spawn(async move {
        while let Some(event) = rx.recv().await {
            handle_sidecar_event(&app_handle, &state_handle, event);
        }
        clear_child_if_current(&state_handle, generation);
    });

    Ok(())
}

#[tauri::command]
pub fn head_track_stop(app: AppHandle, state: State<'_, HeadTrackState>) -> Result<(), String> {
    emit_stop_for_latest_point(&app, &state, now_ms());
    stop_child(&state)
}

#[tauri::command]
pub fn head_track_recenter(state: State<'_, HeadTrackState>) -> Result<(), String> {
    write_control_line(&state, recenter_control_line()?)
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

fn next_generation(state: &HeadTrackState) -> u64 {
    let mut generation = state
        .generation
        .lock()
        .expect("head-track generation lock poisoned");
    *generation += 1;
    *generation
}

fn clear_child_if_current(state: &HeadTrackState, finished_generation: u64) {
    let current_generation = *state
        .generation
        .lock()
        .expect("head-track generation lock poisoned");
    if finished_generation != current_generation {
        return;
    }
    *state.child.lock().expect("head-track child lock poisoned") = None;
}

fn write_control_line(state: &HeadTrackState, line: Vec<u8>) -> Result<(), String> {
    let mut guard = state.child.lock().expect("head-track child lock poisoned");
    let child = guard
        .as_mut()
        .ok_or_else(|| "head-track sidecar not running".to_string())?;
    child
        .write(&line)
        .map_err(|error| format!("head-track sidecar control write failed: {error}"))
}

fn config_control_line(head_pointer: &HeadPointerConfig) -> Result<Vec<u8>, String> {
    control_line(json!({
        "kind": "config",
        "headPointer": head_pointer
    }))
}

fn recenter_control_line() -> Result<Vec<u8>, String> {
    control_line(json!({ "kind": "recenter" }))
}

fn control_line(value: serde_json::Value) -> Result<Vec<u8>, String> {
    let mut line = serde_json::to_vec(&value)
        .map_err(|error| format!("could not encode head-track control message: {error}"))?;
    line.push(b'\n');
    Ok(line)
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

fn emit_stop_for_latest_point(app: &AppHandle, state: &HeadTrackState, ts: u64) {
    let _ = app.emit(EVENT_NAME, HeadSidecarEvent::Stop { ts });
    emit_candidates_for_latest_point(app, state, ts);
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

fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_millis() as u64)
        .unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::super::storage::HeadPointerMovementMode;
    use super::*;

    fn head_pointer_config() -> HeadPointerConfig {
        HeadPointerConfig {
            movement_mode: HeadPointerMovementMode::Edge,
            speed: 5.0,
            distance_to_edge: 0.12,
        }
    }

    #[test]
    fn encodes_head_pointer_config_control_line() {
        let line = String::from_utf8(config_control_line(&head_pointer_config()).unwrap())
            .expect("control line should be UTF-8");

        assert_eq!(
            line,
            "{\"headPointer\":{\"distanceToEdge\":0.12,\"movementMode\":\"edge\",\"speed\":5.0},\"kind\":\"config\"}\n"
        );
    }

    #[test]
    fn encodes_recenter_control_line() {
        let line = String::from_utf8(recenter_control_line().unwrap())
            .expect("control line should be UTF-8");

        assert_eq!(line, "{\"kind\":\"recenter\"}\n");
    }

    #[test]
    fn recenter_requires_a_running_sidecar() {
        let state = HeadTrackState::default();

        assert_eq!(
            write_control_line(&state, recenter_control_line().unwrap()).unwrap_err(),
            "head-track sidecar not running"
        );
    }

    #[test]
    fn stop_event_payload_is_stable_for_host_synthesized_stop() {
        assert_eq!(
            serde_json::to_value(HeadSidecarEvent::Stop { ts: 123 }).unwrap(),
            json!({ "kind": "stop", "ts": 123 })
        );
    }

    #[test]
    fn generation_guard_ignores_previous_sidecar_shutdowns() {
        let state = HeadTrackState::default();
        let previous = next_generation(&state);
        let current = next_generation(&state);

        clear_child_if_current(&state, previous);

        assert_eq!(
            *state
                .generation
                .lock()
                .expect("head-track generation lock poisoned"),
            current
        );
    }

    #[test]
    fn now_ms_returns_epoch_millis() {
        assert!(now_ms() > 0);
    }
}
