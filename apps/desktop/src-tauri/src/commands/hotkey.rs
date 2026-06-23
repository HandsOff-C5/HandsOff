// Global capture hotkeys (#95).
//
// Uses tauri-plugin-global-shortcut (Carbon RegisterEventHotKey under the hood),
// which needs NO Accessibility or Input Monitoring permission — unlike a raw
// CGEventTap. Command + Option + ? is hold-to-capture; Control + Shift + Space
// is tap-to-toggle. The webview drives mic + head tracking from the emitted
// phases.

use serde_json::json;
use tauri::{AppHandle, Emitter};
use tauri_plugin_global_shortcut::{Code, Modifiers, Shortcut, ShortcutState};

const EVENT_NAME: &str = "hotkey://capture";

fn hold_capture_modifiers() -> Modifiers {
    Modifiers::SUPER | Modifiers::ALT | Modifiers::SHIFT
}

fn toggle_capture_modifiers() -> Modifiers {
    Modifiers::CONTROL | Modifiers::SHIFT
}

pub fn hold_capture_shortcut() -> Shortcut {
    Shortcut::new(Some(hold_capture_modifiers()), Code::Slash)
}

pub fn toggle_capture_shortcut() -> Shortcut {
    Shortcut::new(Some(toggle_capture_modifiers()), Code::Space)
}

pub fn capture_shortcuts() -> [Shortcut; 2] {
    [hold_capture_shortcut(), toggle_capture_shortcut()]
}

fn phase_for(shortcut: &Shortcut, state: ShortcutState) -> Option<&'static str> {
    if shortcut.matches(hold_capture_modifiers(), Code::Slash) {
        return match state {
            ShortcutState::Pressed => Some("start"),
            ShortcutState::Released => Some("stop"),
        };
    }

    if shortcut.matches(toggle_capture_modifiers(), Code::Space) {
        return match state {
            ShortcutState::Pressed => Some("toggle"),
            ShortcutState::Released => None,
        };
    }

    None
}

// Plugin handler: map registered shortcuts to the capture phase the webview expects.
pub fn handle_event(app: &AppHandle, shortcut: &Shortcut, state: ShortcutState) {
    let Some(phase) = phase_for(shortcut, state) else {
        return;
    };
    let _ = app.emit(EVENT_NAME, json!({ "phase": phase }));
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hold_capture_shortcut_uses_command_option_question() {
        let shortcut = hold_capture_shortcut();
        assert_eq!(
            shortcut.mods,
            Modifiers::SUPER | Modifiers::ALT | Modifiers::SHIFT
        );
        assert_eq!(shortcut.key, Code::Slash);
    }

    #[test]
    fn toggle_capture_shortcut_uses_control_shift_space() {
        let shortcut = toggle_capture_shortcut();
        assert_eq!(shortcut.mods, Modifiers::CONTROL | Modifiers::SHIFT);
        assert_eq!(shortcut.key, Code::Space);
    }

    #[test]
    fn hold_shortcut_emits_start_and_stop_phases() {
        let shortcut = hold_capture_shortcut();
        assert_eq!(phase_for(&shortcut, ShortcutState::Pressed), Some("start"));
        assert_eq!(phase_for(&shortcut, ShortcutState::Released), Some("stop"));
    }

    #[test]
    fn toggle_shortcut_only_emits_on_press() {
        let shortcut = toggle_capture_shortcut();
        assert_eq!(phase_for(&shortcut, ShortcutState::Pressed), Some("toggle"));
        assert_eq!(phase_for(&shortcut, ShortcutState::Released), None);
    }
}
