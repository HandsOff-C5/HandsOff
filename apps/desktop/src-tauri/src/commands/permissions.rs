// Permission accept/revoke actions for the dashboard (#31).
//
// macOS only grants TCC permissions in response to a real request or a System
// Settings toggle — an app can't grant or revoke them itself. So "accept" =
// trigger the OS prompt, "revoke/manage" = deep-link into System Settings.
//
// `request_media_permissions` reuses the Swift sidecar (`--request-permissions`)
// to fire the microphone + speech prompts, since the Speech/AVFoundation request
// APIs take Objective-C completion blocks that are awkward to call from Rust.

use tauri::AppHandle;
use tauri_plugin_shell::process::CommandEvent;
use tauri_plugin_shell::ShellExt;

const SIDECAR_NAME: &str = "stt-ondevice";

/// Trigger the macOS microphone + speech-recognition prompts and return the
/// resulting grants `{ "speech": "...", "microphone": "..." }`. Requesting an
/// already-decided permission does not re-prompt — it reports the current state
/// — so this is safe to call from an "Allow" button in any state. Resolves once
/// the user responds.
#[tauri::command]
pub async fn request_media_permissions(app: AppHandle) -> Result<serde_json::Value, String> {
    let (mut rx, _child) = app
        .shell()
        .sidecar(SIDECAR_NAME)
        .map_err(|error| format!("sidecar unavailable: {error}"))?
        .args(["--request-permissions"])
        .spawn()
        .map_err(|error| format!("could not spawn sidecar: {error}"))?;

    while let Some(event) = rx.recv().await {
        match event {
            CommandEvent::Stdout(bytes) => {
                if let Some(result) = parse_permissions(&bytes) {
                    return Ok(result);
                }
            }
            CommandEvent::Terminated(_) => break,
            _ => {}
        }
    }
    Err("the permission request did not report a result".to_string())
}

// Pull the `permissions` frame out of the sidecar's stdout lines, if present.
fn parse_permissions(bytes: &[u8]) -> Option<serde_json::Value> {
    let text = std::str::from_utf8(bytes).ok()?;
    text.split('\n')
        .map(str::trim)
        .filter(|line| !line.is_empty())
        .filter_map(|line| serde_json::from_str::<serde_json::Value>(line).ok())
        .find(|value| value.get("kind").and_then(|kind| kind.as_str()) == Some("permissions"))
}

/// Open the System Settings privacy pane for a capability so the user can grant
/// or revoke it. The only reliable cross-version path is the `x-apple` URL.
#[tauri::command]
pub fn open_privacy_settings(pane: String) -> Result<(), String> {
    let anchor = match pane.as_str() {
        "microphone" => "Privacy_Microphone",
        "speech-recognition" => "Privacy_SpeechRecognition",
        "accessibility" => "Privacy_Accessibility",
        "screen-recording" => "Privacy_ScreenCapture",
        other => return Err(format!("unknown privacy pane: {other}")),
    };
    let url = format!("x-apple.systempreferences:com.apple.preference.security?{anchor}");

    #[cfg(target_os = "macos")]
    {
        std::process::Command::new("open")
            .arg(&url)
            .spawn()
            .map_err(|error| format!("could not open System Settings: {error}"))?;
    }
    #[cfg(not(target_os = "macos"))]
    let _ = url;

    Ok(())
}
