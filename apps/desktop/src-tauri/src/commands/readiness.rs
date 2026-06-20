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

#[cfg(not(target_os = "macos"))]
fn accessibility_state() -> &'static str {
    "unknown"
}

#[cfg(not(target_os = "macos"))]
fn screen_recording_state() -> &'static str {
    "unknown"
}

/// Probe macOS capability readiness for the dashboard.
#[tauri::command]
pub fn readiness_probe() -> Value {
    json!({
        "capabilities": [
            { "id": "camera", "kind": "permission", "state": "unknown" },
            { "id": "microphone", "kind": "permission", "state": "unknown" },
            { "id": "cua", "kind": "daemon", "state": "unknown" },
            { "id": "accessibility", "kind": "permission", "state": accessibility_state() },
            { "id": "screen-recording", "kind": "permission", "state": screen_recording_state() }
        ]
    })
}
