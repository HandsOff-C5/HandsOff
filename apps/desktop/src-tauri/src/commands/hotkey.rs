// Right Option + ? capture hotkey (#95).
//
// The CGEventTap lives in the app process (stable bundle identity) — see
// hotkey_tap.m for why. The ObjC bridge forwards raw key events here; this file
// owns the pure hold-state machine and emits `hotkey://capture` {phase} events to
// the webview, which drives mic + head tracking together.

use std::os::raw::c_longlong;
use std::sync::{Mutex, OnceLock};

use serde_json::json;
use tauri::{AppHandle, Emitter};

const EVENT_NAME: &str = "hotkey://capture";

// Right Option device-flag bit (NX_DEVICERALTKEYMASK) — distinct from left (0x20).
const RIGHT_OPTION_MASK: u64 = 0x40;
// CGEventFlags shift bit.
const SHIFT_MASK: u64 = 0x0002_0000;
// `/` key (becomes `?` with shift).
const SLASH_KEY_CODE: i64 = 44;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
struct HotkeyState {
    right_option_held: bool,
    capturing: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum HotkeyPhase {
    None,
    Start,
    Stop,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum NativeEventKind {
    FlagsChanged,
    KeyDown,
}

// Pure decision: given the current state and a raw key event, return the next
// state and whether capture should start/stop. Holding Right Option then pressing
// `?` starts; releasing Right Option stops.
fn decide(
    state: HotkeyState,
    kind: NativeEventKind,
    key_code: i64,
    flags: u64,
) -> (HotkeyState, HotkeyPhase) {
    let mut next = state;
    match kind {
        NativeEventKind::FlagsChanged => {
            next.right_option_held = flags & RIGHT_OPTION_MASK != 0;
            if !next.right_option_held && state.capturing {
                next.capturing = false;
                return (next, HotkeyPhase::Stop);
            }
            (next, HotkeyPhase::None)
        }
        NativeEventKind::KeyDown => {
            let is_question = key_code == SLASH_KEY_CODE && flags & SHIFT_MASK != 0;
            if next.right_option_held && is_question && !next.capturing {
                next.capturing = true;
                return (next, HotkeyPhase::Start);
            }
            (next, HotkeyPhase::None)
        }
    }
}

static STATE: OnceLock<Mutex<HotkeyState>> = OnceLock::new();
static APP: OnceLock<Mutex<Option<AppHandle>>> = OnceLock::new();

fn state_slot() -> &'static Mutex<HotkeyState> {
    STATE.get_or_init(|| Mutex::new(HotkeyState::default()))
}

fn app_slot() -> &'static Mutex<Option<AppHandle>> {
    APP.get_or_init(|| Mutex::new(None))
}

#[cfg(target_os = "macos")]
type HotkeyCallback = extern "C" fn(i32, c_longlong, u64);

#[cfg(target_os = "macos")]
unsafe extern "C" {
    fn handsoff_hotkey_request_permissions();
    fn handsoff_hotkey_install(callback: HotkeyCallback);
}

// Called from the ObjC tap for every flagsChanged / keyDown event.
#[cfg(target_os = "macos")]
extern "C" fn on_native_event(kind: i32, key_code: c_longlong, flags: u64) {
    let kind = match kind {
        0 => NativeEventKind::FlagsChanged,
        1 => NativeEventKind::KeyDown,
        _ => return,
    };
    let phase = {
        let mut state = state_slot().lock().expect("hotkey state poisoned");
        let (next, phase) = decide(*state, kind, key_code, flags);
        *state = next;
        phase
    };
    let phase_str = match phase {
        HotkeyPhase::Start => "start",
        HotkeyPhase::Stop => "stop",
        HotkeyPhase::None => return,
    };
    if let Some(app) = app_slot().lock().expect("hotkey app poisoned").clone() {
        let _ = app.emit(EVENT_NAME, json!({ "phase": phase_str }));
    }
}

// Arm the hotkey: request permissions, then install the tap, retrying every 1.5s
// until macOS lets it through (so granting after launch arms without a relaunch).
pub fn arm(app: AppHandle) {
    *app_slot().lock().expect("hotkey app poisoned") = Some(app.clone());
    #[cfg(target_os = "macos")]
    {
        // Request the TCC prompts, then install the tap. The ObjC side hops to the
        // main run loop and retries every 1.5s until macOS lets it through, so a
        // grant after launch arms the hotkey without a relaunch.
        unsafe {
            handsoff_hotkey_request_permissions();
            handsoff_hotkey_install(on_native_event);
        }
    }
    #[cfg(not(target_os = "macos"))]
    {
        let _ = app;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn s(right: bool, capturing: bool) -> HotkeyState {
        HotkeyState {
            right_option_held: right,
            capturing,
        }
    }

    #[test]
    fn right_option_then_question_starts() {
        let (st, _) = decide(
            HotkeyState::default(),
            NativeEventKind::FlagsChanged,
            61,
            RIGHT_OPTION_MASK,
        );
        assert!(st.right_option_held);
        let (st, phase) = decide(st, NativeEventKind::KeyDown, SLASH_KEY_CODE, SHIFT_MASK);
        assert_eq!(phase, HotkeyPhase::Start);
        assert!(st.capturing);
    }

    #[test]
    fn releasing_right_option_stops() {
        let (_, phase) = decide(s(true, true), NativeEventKind::FlagsChanged, 0, 0);
        assert_eq!(phase, HotkeyPhase::Stop);
    }

    #[test]
    fn left_option_does_not_arm() {
        // Left Option = 0x20, not the right bit.
        let (st, _) = decide(
            HotkeyState::default(),
            NativeEventKind::FlagsChanged,
            58,
            0x20,
        );
        assert!(!st.right_option_held);
        let (_, phase) = decide(st, NativeEventKind::KeyDown, SLASH_KEY_CODE, SHIFT_MASK);
        assert_eq!(phase, HotkeyPhase::None);
    }

    #[test]
    fn question_without_right_option_does_nothing() {
        let (_, phase) = decide(
            HotkeyState::default(),
            NativeEventKind::KeyDown,
            SLASH_KEY_CODE,
            SHIFT_MASK,
        );
        assert_eq!(phase, HotkeyPhase::None);
    }

    #[test]
    fn slash_without_shift_is_not_question() {
        let (st, _) = decide(
            HotkeyState::default(),
            NativeEventKind::FlagsChanged,
            61,
            RIGHT_OPTION_MASK,
        );
        let (_, phase) = decide(st, NativeEventKind::KeyDown, SLASH_KEY_CODE, 0);
        assert_eq!(phase, HotkeyPhase::None);
    }

    #[test]
    fn no_duplicate_start_while_capturing() {
        let (_, phase) = decide(
            s(true, true),
            NativeEventKind::KeyDown,
            SLASH_KEY_CODE,
            SHIFT_MASK,
        );
        assert_eq!(phase, HotkeyPhase::None);
    }
}
