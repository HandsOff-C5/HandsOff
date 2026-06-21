// Native first-run capability probe for the HandsOff readiness surface (#17).
//
// Returns a payload matching the `@handsoff/contracts` `ReadinessProbe` shape:
//   { "capabilities": [ { "id", "kind", "state" }, ... ] }
// The frontend validates it (zod) and maps it to green/yellow/red, so this side
// stays a thin, honest reporter: it returns real macOS permission state where a
// dependency-free system call exists (Accessibility, Screen Recording) and
// `unknown` for capabilities whose probes belong to other lanes — camera and
// microphone authorization land with the capture/STT lanes, and the CUA daemon
// health check lands with the CUA lane.

use serde_json::{json, Value};

// Accessibility (AXIsProcessTrusted) and Screen Recording
// (CGPreflightScreenCaptureAccess) read the current grant without prompting.
#[cfg(target_os = "macos")]
fn accessibility_state() -> &'static str {
    #[link(name = "ApplicationServices", kind = "framework")]
    extern "C" {
        fn AXIsProcessTrusted() -> u8;
    }
    // Safety: no arguments; returns a Boolean. Always safe to call.
    if unsafe { AXIsProcessTrusted() } != 0 {
        "granted"
    } else {
        "denied"
    }
}

#[cfg(target_os = "macos")]
fn screen_recording_state() -> &'static str {
    #[link(name = "CoreGraphics", kind = "framework")]
    extern "C" {
        fn CGPreflightScreenCaptureAccess() -> bool;
    }
    // Safety: no arguments; returns a C bool. Available on macOS 10.15+.
    if unsafe { CGPreflightScreenCaptureAccess() } {
        "granted"
    } else {
        "denied"
    }
}

// Speech recognition authorization for the on-device STT provider (#31). Reads
// `SFSpeechRecognizer.authorizationStatus` via the Objective-C runtime — a class
// method that returns the current grant without ever prompting (the prompt is
// owned by the sidecar when STT starts). Linking the Speech framework registers
// the class with the runtime.
#[cfg(target_os = "macos")]
fn speech_recognition_state() -> &'static str {
    use std::ffi::{c_char, c_void};

    #[link(name = "objc")]
    extern "C" {
        fn objc_getClass(name: *const c_char) -> *const c_void;
        fn sel_registerName(name: *const c_char) -> *const c_void;
        fn objc_msgSend();
    }
    #[link(name = "Speech", kind = "framework")]
    extern "C" {}

    // Safety: `SFSpeechRecognizer` responds to the no-argument class selector
    // `authorizationStatus`, returning an NSInteger. We reinterpret the untyped
    // `objc_msgSend` with that exact signature (required on arm64) and call it; a
    // null class (framework missing) degrades to "unknown".
    let status = unsafe {
        let class = objc_getClass(c"SFSpeechRecognizer".as_ptr());
        if class.is_null() {
            return "unknown";
        }
        let selector = sel_registerName(c"authorizationStatus".as_ptr());
        let msg_send: extern "C" fn(*const c_void, *const c_void) -> isize =
            std::mem::transmute(objc_msgSend as *const c_void);
        msg_send(class, selector)
    };

    // SFSpeechRecognizerAuthorizationStatus: 0 notDetermined, 1 denied,
    // 2 restricted, 3 authorized.
    match status {
        0 => "not-determined",
        1 => "denied",
        2 => "restricted",
        3 => "granted",
        _ => "unknown",
    }
}

// Microphone authorization (#31), read without prompting via
// `AVCaptureDevice.authorizationStatusForMediaType:` with the `AVMediaTypeAudio`
// constant. Note the AVAuthorizationStatus ordering differs from Speech's.
#[cfg(target_os = "macos")]
fn microphone_state() -> &'static str {
    use std::ffi::{c_char, c_void};

    #[link(name = "objc")]
    extern "C" {
        fn objc_getClass(name: *const c_char) -> *const c_void;
        fn sel_registerName(name: *const c_char) -> *const c_void;
        fn objc_msgSend();
    }
    #[link(name = "AVFoundation", kind = "framework")]
    extern "C" {
        // NSString * media-type constant exported by AVFoundation.
        static AVMediaTypeAudio: *const c_void;
    }

    // Safety: `AVCaptureDevice` responds to `authorizationStatusForMediaType:`
    // taking an NSString and returning an NSInteger. We reinterpret `objc_msgSend`
    // with that exact signature (required on arm64); a null class degrades to
    // "unknown".
    let status = unsafe {
        let class = objc_getClass(c"AVCaptureDevice".as_ptr());
        if class.is_null() {
            return "unknown";
        }
        let selector = sel_registerName(c"authorizationStatusForMediaType:".as_ptr());
        let msg_send: extern "C" fn(*const c_void, *const c_void, *const c_void) -> isize =
            std::mem::transmute(objc_msgSend as *const c_void);
        msg_send(class, selector, AVMediaTypeAudio)
    };

    // AVAuthorizationStatus: 0 notDetermined, 1 restricted, 2 denied, 3 authorized.
    match status {
        0 => "not-determined",
        1 => "restricted",
        2 => "denied",
        3 => "granted",
        _ => "unknown",
    }
}

#[cfg(not(target_os = "macos"))]
fn accessibility_state() -> &'static str {
    "unknown"
}

#[cfg(not(target_os = "macos"))]
fn microphone_state() -> &'static str {
    "unknown"
}

#[cfg(not(target_os = "macos"))]
fn screen_recording_state() -> &'static str {
    "unknown"
}

#[cfg(not(target_os = "macos"))]
fn speech_recognition_state() -> &'static str {
    "unknown"
}

/// Probe macOS capability readiness for the dashboard.
#[tauri::command]
pub fn readiness_probe() -> Value {
    json!({
        "capabilities": [
            { "id": "camera", "kind": "permission", "state": "unknown" },
            { "id": "microphone", "kind": "permission", "state": microphone_state() },
            { "id": "speech-recognition", "kind": "permission", "state": speech_recognition_state() },
            { "id": "cua", "kind": "daemon", "state": "unknown" },
            { "id": "accessibility", "kind": "permission", "state": accessibility_state() },
            { "id": "screen-recording", "kind": "permission", "state": screen_recording_state() }
        ]
    })
}
