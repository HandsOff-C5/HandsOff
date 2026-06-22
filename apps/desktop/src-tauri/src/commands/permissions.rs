// Permission accept/revoke actions for the dashboard (#31).
//
// macOS only grants TCC permissions in response to a real request or a System
// Settings toggle — an app can't grant or revoke them itself. So "accept" =
// trigger the OS prompt, "revoke/manage" = deep-link into System Settings.
//
// `request_media_permissions` asks through the app bundle so TCC sees the
// privacy usage strings in HandsOff.app/Contents/Info.plist. The raw STT helper
// cannot request Speech authorization directly: macOS crashes it before stdout
// can carry a result. `media_permission_states` uses the sidecar's passive
// `--permission-state` mode so readiness checks never prompt on their own.

use serde_json::{json, Value};
use tauri::AppHandle;
use tauri_plugin_shell::process::CommandEvent;
use tauri_plugin_shell::ShellExt;

const SIDECAR_NAME: &str = "stt-ondevice";

/// Trigger the macOS microphone + speech-recognition prompts for any
/// undetermined grant and return the resulting states
/// `{ "speech": "...", "microphone": "..." }`. Already-decided permissions are
/// read without re-prompting, so this is safe to call from an "Allow" button in
/// any state. Resolves once the user responds to any visible prompt.
#[tauri::command]
pub async fn request_media_permissions(app: AppHandle) -> Result<serde_json::Value, String> {
    let app_permissions = request_app_media_permissions();
    media_permission_states(&app).await.or(Ok(app_permissions))
}

pub async fn media_permission_states(app: &AppHandle) -> Result<serde_json::Value, String> {
    run_media_permissions_helper(app, "--permission-state").await
}

async fn run_media_permissions_helper(
    app: &AppHandle,
    mode: &str,
) -> Result<serde_json::Value, String> {
    if let Some(result) = media_permissions_from_bundled_helper(mode)? {
        return Ok(result);
    }
    let (mut rx, _child) = app
        .shell()
        .sidecar(SIDECAR_NAME)
        .map_err(|error| format!("sidecar unavailable: {error}"))?
        .args([mode])
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

fn media_permissions_from_bundled_helper(mode: &str) -> Result<Option<serde_json::Value>, String> {
    let helper = std::env::current_exe()
        .ok()
        .and_then(|path| path.parent().map(|parent| parent.join(SIDECAR_NAME)))
        .filter(|path| path.is_file());
    let Some(helper) = helper else {
        return Ok(None);
    };

    let output = std::process::Command::new(&helper)
        .arg(mode)
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

#[cfg(target_os = "macos")]
extern "C" {
    fn handsoff_request_speech_authorization() -> i32;
    fn handsoff_request_microphone_authorization() -> i32;
}

#[cfg(target_os = "macos")]
fn request_app_media_permissions() -> Value {
    // Safety: these functions are compiled into the app from native_permissions.m
    // and synchronously return Apple's documented authorization enum values.
    let speech = unsafe { handsoff_request_speech_authorization() };
    let microphone = unsafe { handsoff_request_microphone_authorization() };
    permissions_value(
        speech_authorization_state(speech),
        microphone_authorization_state(microphone),
    )
}

#[cfg(not(target_os = "macos"))]
fn request_app_media_permissions() -> Value {
    permissions_value("unknown", "unknown")
}

fn permissions_value(speech: &'static str, microphone: &'static str) -> Value {
    json!({
        "kind": "permissions",
        "speech": speech,
        "microphone": microphone,
    })
}

fn speech_authorization_state(status: i32) -> &'static str {
    match status {
        0 => "not-determined",
        1 => "denied",
        2 => "restricted",
        3 => "granted",
        _ => "unknown",
    }
}

fn microphone_authorization_state(status: i32) -> &'static str {
    match status {
        0 => "not-determined",
        1 => "restricted",
        2 => "denied",
        3 => "granted",
        _ => "unknown",
    }
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

    #[test]
    fn maps_native_speech_authorization_statuses() {
        assert_eq!(speech_authorization_state(0), "not-determined");
        assert_eq!(speech_authorization_state(1), "denied");
        assert_eq!(speech_authorization_state(2), "restricted");
        assert_eq!(speech_authorization_state(3), "granted");
        assert_eq!(speech_authorization_state(99), "unknown");
    }

    #[test]
    fn maps_native_microphone_authorization_statuses() {
        assert_eq!(microphone_authorization_state(0), "not-determined");
        assert_eq!(microphone_authorization_state(1), "restricted");
        assert_eq!(microphone_authorization_state(2), "denied");
        assert_eq!(microphone_authorization_state(3), "granted");
        assert_eq!(microphone_authorization_state(99), "unknown");
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
