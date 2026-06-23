// Option + ? capture hotkey (#95).
//
// Uses tauri-plugin-global-shortcut (Carbon RegisterEventHotKey under the hood),
// which needs NO Accessibility or Input Monitoring permission — unlike a raw
// CGEventTap. Trade-off: global shortcuts can't distinguish left vs right Option,
// so the combo is Option + ? (either Option). The plugin reports Pressed/Released,
// so hold-to-talk works: Pressed emits `hotkey://capture {phase:"start"}`,
// Released emits `{phase:"stop"}`, and the webview drives mic + head tracking.

use serde_json::json;
use tauri::{AppHandle, Emitter};
use tauri_plugin_global_shortcut::{Code, Modifiers, Shortcut, ShortcutState};

const EVENT_NAME: &str = "hotkey://capture";

// Command + ? — i.e. Command + Shift + Slash (`?` is Shift+`/`). One-handed and,
// critically, Command is a non-Option/Shift modifier: macOS Sequoia silently
// refuses to register global hotkeys whose only modifiers are Shift and/or Option
// (anti-keylogger measure, error -9868), so Cmd is required for this to install.
// `Modifiers::SUPER` is the Command key on macOS.
pub fn capture_shortcut() -> Shortcut {
    Shortcut::new(Some(Modifiers::SUPER | Modifiers::SHIFT), Code::Slash)
}

// Plugin handler: map Pressed/Released to the capture phase the webview expects.
pub fn handle_event(app: &AppHandle, state: ShortcutState) {
    let phase = match state {
        ShortcutState::Pressed => "start",
        ShortcutState::Released => "stop",
    };
    let _ = app.emit(EVENT_NAME, json!({ "phase": phase }));
}
