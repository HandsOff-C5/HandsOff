// On-device STT commands (#31, AD2): the default, provisioning-free provider.
//
// Spawns the native Swift sidecar that runs Apple's on-device speech
// recognition (SFSpeechRecognizer + AVAudioEngine) and forwards its events to
// the webview on `stt://event`. No network, no API key — audio stays on device.
//
// The sidecar emits newline-delimited JSON (ready/partial/final/error). The
// shell plugin line-buffers stdout, so each `Stdout` event is normally one line;
// `forward_lines` splits defensively in case of batching. `stt_ondevice_stop`
// (or a restart) terminates the running child.

use std::sync::Mutex;

use tauri::{AppHandle, Emitter, State};
use tauri_plugin_shell::process::{CommandChild, CommandEvent};
use tauri_plugin_shell::ShellExt;

const SIDECAR_NAME: &str = "stt-ondevice";
const EVENT_NAME: &str = "stt://event";

// Holds the running sidecar child so a stop or restart can terminate it. `None`
// when no session is active.
#[derive(Default)]
pub struct OnDeviceSttState {
    child: Mutex<Option<CommandChild>>,
}

fn take_child(state: &OnDeviceSttState) -> Option<CommandChild> {
    state.child.lock().expect("stt child lock poisoned").take()
}

/// Start an on-device recognition session: spawn the sidecar and stream its
/// events to the webview. A restart terminates any prior session first.
#[tauri::command]
pub async fn stt_ondevice_start(
    app: AppHandle,
    state: State<'_, OnDeviceSttState>,
) -> Result<(), String> {
    if let Some(previous) = take_child(&state) {
        let _ = previous.kill();
    }

    let sidecar = app
        .shell()
        .sidecar(SIDECAR_NAME)
        .map_err(|error| format!("start-failed: sidecar unavailable: {error}"))?;
    let (mut rx, child) = sidecar
        .spawn()
        .map_err(|error| format!("start-failed: could not spawn sidecar: {error}"))?;

    *state.child.lock().expect("stt child lock poisoned") = Some(child);

    let app_handle = app.clone();
    tauri::async_runtime::spawn(async move {
        while let Some(event) = rx.recv().await {
            match event {
                CommandEvent::Stdout(bytes) => forward_lines(&app_handle, &bytes),
                CommandEvent::Error(message) => {
                    let _ = app_handle.emit(
                        EVENT_NAME,
                        serde_json::json!({
                            "kind": "error",
                            "errorKind": "provider-unavailable",
                            "message": message,
                        }),
                    );
                }
                CommandEvent::Terminated(_) => {
                    let _ =
                        app_handle.emit(EVENT_NAME, serde_json::json!({ "kind": "terminated" }));
                    break;
                }
                _ => {}
            }
        }
    });

    Ok(())
}

// Re-emit each JSON line the sidecar produced verbatim to the webview; the
// `mapOnDeviceEvent` mapper on the TS side validates the shape. Non-JSON lines
// are ignored.
fn forward_lines(app: &AppHandle, bytes: &[u8]) {
    let Ok(text) = std::str::from_utf8(bytes) else {
        return;
    };
    for line in text
        .split('\n')
        .map(str::trim)
        .filter(|line| !line.is_empty())
    {
        if let Ok(value) = serde_json::from_str::<serde_json::Value>(line) {
            let _ = app.emit(EVENT_NAME, value);
        }
    }
}

/// Stop the active on-device recognition session, if any. Idempotent.
#[tauri::command]
pub fn stt_ondevice_stop(state: State<'_, OnDeviceSttState>) -> Result<(), String> {
    if let Some(child) = take_child(&state) {
        child
            .kill()
            .map_err(|error| format!("stop failed: {error}"))?;
    }
    Ok(())
}
