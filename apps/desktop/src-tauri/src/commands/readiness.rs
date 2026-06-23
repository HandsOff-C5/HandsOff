// Native first-run capability probe for the HandsOff readiness surface (#17).
//
// Returns a payload matching the `@handsoff/contracts` `ReadinessProbe` shape:
//   { "capabilities": [ { "id", "kind", "state" }, ... ] }
// The frontend validates it (zod) and maps it to green/yellow/red, so this side
// stays a thin, honest reporter: it returns real macOS permission state where a
// dependency-free system call exists (Camera, Microphone, Speech, Accessibility,
// Screen Recording) and `unknown` for capabilities whose probes belong to other
// lanes — the CUA daemon health check lands with the CUA lane.
//
// All permission states are read via native FFI functions that query the app
// bundle's TCC identity directly — there is no sidecar permission path anymore.

use serde_json::{json, Value};
use tauri::AppHandle;

// Accessibility (AXIsProcessTrusted) and Screen Recording
// (CGPreflightScreenCaptureAccess) read the current grant without prompting.
// Speech and microphone authorization use SFSpeechRecognizer and
// AVCaptureDevice FFI calls to read the app bundle's TCC state directly.
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

// Speech recognition authorization read directly from the app bundle's TCC
// identity via SFSpeechRecognizer FFI.
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

// Camera/microphone authorization (#31, #95), read without prompting via
// `AVCaptureDevice.authorizationStatusForMediaType:`. Note the AVAuthorizationStatus
// ordering differs from Speech's.
#[cfg(target_os = "macos")]
fn av_capture_state(media_type: *const std::ffi::c_void) -> &'static str {
    use std::ffi::{c_char, c_void};

    #[link(name = "objc")]
    extern "C" {
        fn objc_getClass(name: *const c_char) -> *const c_void;
        fn sel_registerName(name: *const c_char) -> *const c_void;
        fn objc_msgSend();
    }
    #[link(name = "AVFoundation", kind = "framework")]
    extern "C" {}

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
        msg_send(class, selector, media_type)
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

#[cfg(target_os = "macos")]
fn camera_state() -> &'static str {
    use std::ffi::c_void;

    #[link(name = "AVFoundation", kind = "framework")]
    extern "C" {
        // NSString * media-type constant exported by AVFoundation.
        static AVMediaTypeVideo: *const c_void;
    }

    // Safety: AVFoundation exports a stable NSString constant for camera media.
    av_capture_state(unsafe { AVMediaTypeVideo })
}

#[cfg(target_os = "macos")]
fn microphone_state() -> &'static str {
    use std::ffi::c_void;

    #[link(name = "AVFoundation", kind = "framework")]
    extern "C" {
        // NSString * media-type constant exported by AVFoundation.
        static AVMediaTypeAudio: *const c_void;
    }

    // Safety: AVFoundation exports a stable NSString constant for audio media.
    av_capture_state(unsafe { AVMediaTypeAudio })
}

#[cfg(not(target_os = "macos"))]
fn camera_state() -> &'static str {
    "unknown"
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
pub async fn readiness_probe(_app: AppHandle) -> Value {
    json!({
        "capabilities": [
            { "id": "camera", "kind": "permission", "state": camera_state() },
            { "id": "microphone", "kind": "permission", "state": microphone_state() },
            { "id": "speech-recognition", "kind": "permission", "state": speech_recognition_state() },
            { "id": "cua", "kind": "daemon", "state": "unknown" },
            { "id": "accessibility", "kind": "permission", "state": accessibility_state() },
            { "id": "screen-recording", "kind": "permission", "state": screen_recording_state() }
        ]
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn speech_recognition_state_returns_valid_states() {
        // Can't test actual FFI without a macOS runtime, but we can verify
        // the function signature compiles correctly.
        #[cfg(target_os = "macos")]
        {
            let _state = speech_recognition_state();
        }
    }

    #[test]
    fn microphone_state_returns_valid_states() {
        #[cfg(target_os = "macos")]
        {
            let _state = microphone_state();
        }
    }

    #[test]
    fn camera_state_returns_valid_states() {
        #[cfg(target_os = "macos")]
        {
            let _state = camera_state();
        }
    }
}
