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

const EVENT_NAME: &str = "stt://head";
const SIDECAR_NAME: &str = "head-track";

#[derive(Clone, Default)]
pub struct HeadTrackState {
    child: Arc<Mutex<Option<CommandChild>>>,
    latest_point: Arc<Mutex<Option<HeadPoint>>>,
    stdout_buffer: Arc<Mutex<String>>,
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

fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_millis() as u64)
        .unwrap_or(0)
}
