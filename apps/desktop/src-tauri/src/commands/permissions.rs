// Permission accept/revoke actions for the dashboard (#31).
//
// macOS only grants TCC permissions in response to a real request or a System
// Settings toggle — an app can't grant or revoke them itself. So "accept" =
// trigger the OS prompt, "revoke/manage" = deep-link into System Settings.
//
// `request_media_permissions` asks through the app bundle so TCC sees the
// privacy usage strings in HandsOff.app/Contents/Info.plist. All permission
// state is read via native FFI functions that query the app bundle's TCC
// identity directly — there is no sidecar permission path anymore.

use serde_json::{json, Value};
use tauri::AppHandle;

/// Trigger the macOS microphone + speech-recognition prompts for any
/// undetermined grant and return the resulting states
/// `{ "speech": "...", "microphone": "..." }`. Already-decided permissions are
/// read without re-prompting, so this is safe to call from an "Allow" button in
/// any state. Resolves once the user responds to any visible prompt.
#[tauri::command]
pub async fn request_media_permissions(_app: AppHandle) -> Result<serde_json::Value, String> {
    Ok(request_app_media_permissions())
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

    #[test]
    fn permissions_value_returns_expected_structure() {
        let value = permissions_value("granted", "denied");
        assert_eq!(value["kind"], "permissions");
        assert_eq!(value["speech"], "granted");
        assert_eq!(value["microphone"], "denied");
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
