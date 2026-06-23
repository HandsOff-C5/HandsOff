// Command + Option + / capture hotkey (#95).
//
// Uses tauri-plugin-global-shortcut (Carbon RegisterEventHotKey under the hood),
// which needs NO Accessibility or Input Monitoring permission — unlike a raw
// CGEventTap. The plugin cannot distinguish left-side vs right-side modifiers,
// but this chord is reachable with the right Command and right Option keys plus
// `/`, and it avoids macOS's reserved Command + ? Help shortcut. Pressed emits
// `hotkey://capture {phase:"start"}`, Released emits `{phase:"stop"}`, and the
// webview drives mic + head tracking.

use serde_json::json;
use tauri::{AppHandle, Emitter};
use tauri_plugin_global_shortcut::{Code, Modifiers, Shortcut, ShortcutState};

const EVENT_NAME: &str = "hotkey://capture";

// `Modifiers::SUPER` is Command on macOS. Include Command so Sequoia accepts the
// registration; include Option to keep the physical chord on the right side
// without colliding with the standard Command + ? Help shortcut.
pub fn capture_shortcut() -> Shortcut {
    Shortcut::new(Some(Modifiers::SUPER | Modifiers::ALT), Code::Slash)
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
    fn capture_shortcut_uses_right_hand_command_option_slash_pairing() {
        let shortcut = capture_shortcut();
        assert_eq!(shortcut.mods, Modifiers::SUPER | Modifiers::ALT);
        assert_eq!(shortcut.key, Code::Slash);
    }
}
