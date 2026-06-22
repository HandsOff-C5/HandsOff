// On-device STT commands (#31, AD2): the default, provisioning-free provider.
//
// Runs Apple's on-device speech recognition (SFSpeechRecognizer + AVAudioEngine)
// in the app process and forwards native events to the webview on `stt://event`.
// No network, no API key — audio stays on device.
//
// The Rust/native boundary is typed: native events serialize as JSON with a
// `kind` discriminator, and the Rust side parses into strongly-typed structs
// that fail loudly on malformed input.

use serde::Deserialize;
use std::ffi::CStr;
use std::os::raw::c_char;
use std::sync::{Mutex, OnceLock};

use tauri::{AppHandle, Emitter, State};

const EVENT_NAME: &str = "stt://event";

// Typed native event structs matching the Objective-C emission format.

#[derive(Debug, Deserialize)]
#[serde(tag = "kind", rename_all = "kebab-case")]
enum NativeSttEvent {
    Partial(NativePartial),
    Final(NativeFinal),
    Error(NativeError),
    Ready,
}

#[derive(Debug, Deserialize)]
struct NativePartial {
    text: String,
}

#[derive(Debug, Deserialize)]
struct NativeFinal {
    text: String,
    confidence: f64,
    latency_ms: u64,
}

#[derive(Debug, Deserialize)]
struct NativeError {
    error_kind: String,
    message: String,
    #[serde(default)]
    permission_status: Option<i32>,
}

#[cfg(target_os = "macos")]
type SttEventCallback = extern "C" fn(*const c_char);

#[cfg(target_os = "macos")]
unsafe extern "C" {
    fn handsoff_stt_start(callback: SttEventCallback) -> i32;
    fn handsoff_stt_stop();
}

static APP_HANDLE: OnceLock<Mutex<Option<AppHandle>>> = OnceLock::new();

fn app_handle_slot() -> &'static Mutex<Option<AppHandle>> {
    APP_HANDLE.get_or_init(|| Mutex::new(None))
}

// Holds whether the native app-process recognizer is active so stop/restart stay
// idempotent. The actual AVAudioEngine/SFSpeechRecognitionTask are retained by
// the Objective-C bridge.
#[derive(Default)]
pub struct OnDeviceSttState {
    active: Mutex<bool>,
}

fn set_active(state: &OnDeviceSttState, active: bool) {
    *state.active.lock().expect("stt active lock poisoned") = active;
}

fn is_active(state: &OnDeviceSttState) -> bool {
    *state.active.lock().expect("stt active lock poisoned")
}

/// Start an on-device recognition session in the HandsOff app process. A
/// restart terminates any prior session first.
#[tauri::command]
pub async fn stt_ondevice_start(
    app: AppHandle,
    state: State<'_, OnDeviceSttState>,
) -> Result<(), String> {
    if is_active(&state) {
        stop_native_recognition();
        set_active(&state, false);
    }

    *app_handle_slot()
        .lock()
        .expect("stt app handle lock poisoned") = Some(app);

    start_native_recognition()?;
    set_active(&state, true);
    Ok(())
}

#[cfg(target_os = "macos")]
fn start_native_recognition() -> Result<(), String> {
    let started = unsafe { handsoff_stt_start(native_stt_event) };
    if started == 0 {
        return Err("start-failed: native on-device recognition unavailable".to_string());
    }
    Ok(())
}

#[cfg(not(target_os = "macos"))]
fn start_native_recognition() -> Result<(), String> {
    Err("start-failed: native on-device recognition is only available on macOS".to_string())
}

#[cfg(target_os = "macos")]
fn stop_native_recognition() {
    unsafe { handsoff_stt_stop() };
}

#[cfg(not(target_os = "macos"))]
fn stop_native_recognition() {}

extern "C" fn native_stt_event(json: *const c_char) {
    let Some(value) = parse_native_event(json) else {
        return;
    };
    let app = app_handle_slot()
        .lock()
        .expect("stt app handle lock poisoned")
        .clone();
    if let Some(app) = app {
        let _ = app.emit(EVENT_NAME, value);
    }
}

fn parse_native_event(json: *const c_char) -> Option<serde_json::Value> {
    if json.is_null() {
        return None;
    }
    let text = unsafe { CStr::from_ptr(json) }.to_str().ok()?;
    let text = text.trim();

    // Parse into the typed enum, then convert back to JSON for emission.
    // This validates the structure and fails loudly on malformed native events.
    let native: NativeSttEvent = serde_json::from_str(text).ok()?;

    Some(match native {
        NativeSttEvent::Partial(p) => serde_json::json!({
            "kind": "partial",
            "text": p.text,
        }),
        NativeSttEvent::Final(f) => serde_json::json!({
            "kind": "final",
            "text": f.text,
            "confidence": f.confidence,
            "latencyMs": f.latency_ms,
        }),
        NativeSttEvent::Error(e) => {
            let mut error = serde_json::json!({
                "kind": "error",
                "errorKind": e.error_kind,
                "message": e.message,
            });
            // Include permission status if present for structured permission state handling.
            if let Some(status) = e.permission_status {
                error["permissionStatus"] = serde_json::json!(status);
            }
            error
        }
        NativeSttEvent::Ready => serde_json::json!({
            "kind": "ready",
        }),
    })
}

/// Stop the active on-device recognition session, if any. Idempotent.
#[tauri::command]
pub fn stt_ondevice_stop(state: State<'_, OnDeviceSttState>) -> Result<(), String> {
    if is_active(&state) {
        stop_native_recognition();
        set_active(&state, false);
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use std::ffi::{CStr, CString};
    #[cfg(target_os = "macos")]
    use std::os::raw::c_char;
    use std::ptr;
    #[cfg(target_os = "macos")]
    use std::sync::{Mutex, OnceLock};

    use super::parse_native_event;
    #[cfg(target_os = "macos")]
    use super::SttEventCallback;

    #[cfg(target_os = "macos")]
    unsafe extern "C" {
        fn handsoff_emit_stt_error(
            callback: SttEventCallback,
            kind: *const c_char,
            message: *const c_char,
        );
        fn handsoff_emit_stt_final(
            callback: SttEventCallback,
            text: *const c_char,
            confidence: f64,
            latency_ms: i64,
        );
        fn handsoff_emit_stt_partial(callback: SttEventCallback, text: *const c_char);
        fn handsoff_emit_stt_ready(callback: SttEventCallback);
        fn handsoff_stt_engine_for_macos_major(
            major_version: i32,
            speech_analyzer_compiled: i32,
        ) -> i32;
    }

    #[cfg(target_os = "macos")]
    static CAPTURED_NATIVE_EVENTS: OnceLock<Mutex<Vec<String>>> = OnceLock::new();

    #[cfg(target_os = "macos")]
    fn captured_native_events() -> &'static Mutex<Vec<String>> {
        CAPTURED_NATIVE_EVENTS.get_or_init(|| Mutex::new(Vec::new()))
    }

    #[cfg(target_os = "macos")]
    extern "C" fn capture_native_event(json: *const c_char) {
        if json.is_null() {
            return;
        }
        let text = unsafe { CStr::from_ptr(json) }
            .to_string_lossy()
            .into_owned();
        captured_native_events()
            .lock()
            .expect("native event capture lock poisoned")
            .push(text);
    }

    #[cfg(target_os = "macos")]
    fn take_captured_event() -> serde_json::Value {
        let json = captured_native_events()
            .lock()
            .expect("native event capture lock poisoned")
            .pop()
            .expect("native helper should emit one event");
        let c_json = CString::new(json).expect("native event should not contain nul bytes");
        parse_native_event(c_json.as_ptr()).expect("native helper event should parse")
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn native_emit_helpers_preserve_rust_event_contract() {
        captured_native_events()
            .lock()
            .expect("native event capture lock poisoned")
            .clear();

        let text = CString::new("hello").unwrap();
        unsafe { handsoff_emit_stt_partial(capture_native_event, text.as_ptr()) };
        let partial = take_captured_event();
        assert_eq!(partial["kind"], "partial");
        assert_eq!(partial["text"], "hello");

        let text = CString::new("done").unwrap();
        unsafe { handsoff_emit_stt_final(capture_native_event, text.as_ptr(), 0.75, 42) };
        let final_event = take_captured_event();
        assert_eq!(final_event["kind"], "final");
        assert_eq!(final_event["text"], "done");
        assert_eq!(final_event["confidence"], 0.75);
        assert_eq!(final_event["latencyMs"], 42);

        let kind = CString::new("start-failed").unwrap();
        let message = CString::new("failed").unwrap();
        unsafe { handsoff_emit_stt_error(capture_native_event, kind.as_ptr(), message.as_ptr()) };
        let error = take_captured_event();
        assert_eq!(error["kind"], "error");
        assert_eq!(error["errorKind"], "start-failed");
        assert_eq!(error["message"], "failed");

        unsafe { handsoff_emit_stt_ready(capture_native_event) };
        let ready = take_captured_event();
        assert_eq!(ready["kind"], "ready");
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn selects_speech_analyzer_only_when_runtime_and_sdk_support_it() {
        let fallback = unsafe { handsoff_stt_engine_for_macos_major(25, 1) };
        let analyzer = unsafe { handsoff_stt_engine_for_macos_major(26, 1) };
        let sdk_fallback = unsafe { handsoff_stt_engine_for_macos_major(26, 0) };

        assert_eq!(fallback, 1);
        assert_eq!(analyzer, 2);
        assert_eq!(sdk_fallback, 1);
    }

    #[test]
    fn parses_native_partial_event() {
        let json = CString::new(r#"{"kind":"partial","text":"hello"}"#).unwrap();
        let value = parse_native_event(json.as_ptr()).expect("native event should parse");
        assert_eq!(value["kind"], "partial");
        assert_eq!(value["text"], "hello");
    }

    #[test]
    fn parses_native_final_event() {
        let json = CString::new(
            r#"{"kind":"final","text":"hello world","confidence":0.93,"latency_ms":120}"#,
        )
        .unwrap();
        let value = parse_native_event(json.as_ptr()).expect("native event should parse");
        assert_eq!(value["kind"], "final");
        assert_eq!(value["text"], "hello world");
        assert_eq!(value["confidence"], 0.93);
        assert_eq!(value["latencyMs"], 120);
    }

    #[test]
    fn parses_native_error_event() {
        let json = CString::new(
            r#"{"kind":"error","error_kind":"mic-permission","message":"not authorized"}"#,
        )
        .unwrap();
        let value = parse_native_event(json.as_ptr()).expect("native event should parse");
        assert_eq!(value["kind"], "error");
        assert_eq!(value["errorKind"], "mic-permission");
        assert_eq!(value["message"], "not authorized");
    }

    #[test]
    fn parses_native_ready_event() {
        let json = CString::new(r#"{"kind":"ready"}"#).unwrap();
        let value = parse_native_event(json.as_ptr()).expect("native event should parse");
        assert_eq!(value["kind"], "ready");
    }

    #[test]
    fn drops_invalid_native_event() {
        let json = CString::new("not json").unwrap();
        assert!(parse_native_event(json.as_ptr()).is_none());
        assert!(parse_native_event(ptr::null()).is_none());
    }

    #[test]
    fn drops_malformed_native_event() {
        // Missing required fields
        let json = CString::new(r#"{"kind":"final"}"#).unwrap();
        assert!(parse_native_event(json.as_ptr()).is_none());

        // Unknown kind
        let json = CString::new(r#"{"kind":"unknown"}"#).unwrap();
        assert!(parse_native_event(json.as_ptr()).is_none());
    }
}
