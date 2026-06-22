// Permission accept/revoke actions for the dashboard (#31).
//
// macOS only grants TCC permissions in response to a real request or a System
// Settings toggle — an app can't grant or revoke them itself. The raw STT helper
// reports current media states; manage/revoke actions deep-link into System
// Settings.
//
// `request_media_permissions` asks the Swift sidecar for its current microphone
// and speech states. The helper is a raw sidecar process, so it must not call
// macOS TCC request APIs directly; missing grants are handled through the System
// Settings management links.

use tauri::AppHandle;
use tauri_plugin_shell::process::CommandEvent;
use tauri_plugin_shell::ShellExt;

const SIDECAR_NAME: &str = "stt-ondevice";

/// Return the helper's microphone + speech-recognition grants as
/// `{ "speech": "...", "microphone": "..." }` without prompting. Resolves once
/// the helper reports its current state.
#[tauri::command]
pub async fn request_media_permissions(app: AppHandle) -> Result<serde_json::Value, String> {
    media_permission_states(&app).await
}

pub async fn media_permission_states(app: &AppHandle) -> Result<serde_json::Value, String> {
    if let Some(result) = media_permission_states_from_bundled_helper()? {
        return Ok(result);
    }

    let (mut rx, _child) = app
        .shell()
        .sidecar(SIDECAR_NAME)
        .map_err(|error| format!("sidecar unavailable: {error}"))?
        .args(["--request-permissions"])
        .spawn()
        .map_err(|error| format!("could not spawn sidecar: {error}"))?;

    let mut stdout = Vec::new();
    while let Some(event) = rx.recv().await {
        match event {
            CommandEvent::Stdout(bytes) => {
                stdout.extend_from_slice(&bytes);
                if let Some(result) = parse_permissions(&stdout) {
                    return Ok(result);
                }
            }
            CommandEvent::Terminated(_) => break,
            _ => {}
        }
    }
    Err("the permission request did not report a result".to_string())
}

fn media_permission_states_from_bundled_helper() -> Result<Option<serde_json::Value>, String> {
    let helper = std::env::current_exe()
        .ok()
        .and_then(|path| path.parent().map(|parent| parent.join(SIDECAR_NAME)))
        .filter(|path| path.is_file());
    let Some(helper) = helper else {
        return Ok(None);
    };

    let output = std::process::Command::new(&helper)
        .arg("--request-permissions")
        .output()
        .map_err(|error| format!("could not run bundled sidecar: {error}"))?;
    parse_permissions(&output.stdout)
        .map(Some)
        .ok_or_else(|| "the bundled permission request did not report a result".to_string())
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_permissions_frame_after_stdout_accumulates() {
        let mut stdout = Vec::new();
        stdout.extend_from_slice(br#"{"kind":"per"#);
        assert!(parse_permissions(&stdout).is_none());

        stdout.extend_from_slice(br#"missions","speech":"not-determined","microphone":"granted"}"#);
        let result = parse_permissions(&stdout).expect("complete permissions frame should parse");

        assert_eq!(
            result.get("speech").and_then(serde_json::Value::as_str),
            Some("not-determined")
        );
        assert_eq!(
            result.get("microphone").and_then(serde_json::Value::as_str),
            Some("granted")
        );
    }
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
