// Control + Shift + Space capture hotkey (#95).
//
// Uses tauri-plugin-global-shortcut (Carbon RegisterEventHotKey under the hood),
// which needs NO Accessibility or Input Monitoring permission — unlike a raw
// CGEventTap. Pressed emits `hotkey://capture {phase:"start"}`, Released emits
// `{phase:"stop"}`, and the webview drives mic + head tracking.

use serde_json::json;
use tauri::{AppHandle, Emitter};
use tauri_plugin_global_shortcut::{Code, Modifiers, Shortcut, ShortcutState};

const EVENT_NAME: &str = "hotkey://capture";

pub fn capture_shortcut() -> Shortcut {
    Shortcut::new(Some(Modifiers::CONTROL | Modifiers::SHIFT), Code::Space)
}

// Plugin handler: map Pressed/Released to the capture phase the webview expects.
pub fn handle_event(app: &AppHandle, state: ShortcutState) {
    let phase = match state {
        ShortcutState::Pressed => "start",
        ShortcutState::Released => "stop",
    };
    let _ = app.emit(EVENT_NAME, json!({ "phase": phase }));
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn capture_shortcut_uses_control_shift_space() {
        let shortcut = capture_shortcut();
        assert_eq!(shortcut.mods, Modifiers::CONTROL | Modifiers::SHIFT);
        assert_eq!(shortcut.key, Code::Space);
    }
}
