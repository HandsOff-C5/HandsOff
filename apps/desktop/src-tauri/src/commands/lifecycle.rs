// Engine process lifecycle — Gate L0 (accessory / menu-bar-first app).
//
// Director is menu-bar-first: the engine runs windowless so closing a window
// (e.g. the Home Dashboard on stage during the demo) must never stop the process
// or the loopback bridge (`commands::bridge::serve`). This module holds the pure
// lifecycle *decisions* so they are unit-testable; `main.rs` wires them to the
// Tauri runtime callbacks (`RunEvent::ExitRequested`, `WindowEvent::CloseRequested`)
// and the macOS accessory activation policy. See
// HandsOff-Knowledge/docs/director-ui-tasks-track-s.md § Gate L0.

/// What to do when a window receives a close request.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum WindowCloseAction {
    /// Hide the window and keep the engine alive (the Home Dashboard re-opens via
    /// the menu-bar `openHome` command in G1). Closing it must not destroy it.
    HideAndKeepAlive,
    /// Let the window close normally (auxiliary windows, e.g. overlays).
    AllowClose,
}

/// Decide how a window's close request is handled.
///
/// The `main` window is the Home Dashboard — it hides instead of closing so the
/// engine and bridge survive and the menu bar can re-show it. Every other window
/// closes normally.
pub fn window_close_action(window_label: &str) -> WindowCloseAction {
    match window_label {
        "main" => WindowCloseAction::HideAndKeepAlive,
        _ => WindowCloseAction::AllowClose,
    }
}

/// Decide whether to prevent the process from exiting on a Tauri `ExitRequested`.
///
/// `code` is `None` when the OS/last-window-close requested the exit (Director
/// must survive this — the engine is menu-bar-first), and `Some` when requested
/// programmatically via `AppHandle::exit` / `AppHandle::restart` (the existing
/// `permissions::restart_app` command relies on restart working, so those must be
/// allowed through).
pub fn should_prevent_exit(code: Option<i32>) -> bool {
    code.is_none()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn main_window_hides_instead_of_closing() {
        assert_eq!(
            window_close_action("main"),
            WindowCloseAction::HideAndKeepAlive
        );
    }

    #[test]
    fn auxiliary_windows_close_normally() {
        assert_eq!(
            window_close_action("overlay"),
            WindowCloseAction::AllowClose
        );
        assert_eq!(
            window_close_action("preferences"),
            WindowCloseAction::AllowClose
        );
    }

    #[test]
    fn last_window_close_keeps_the_engine_alive() {
        // None == user interaction / last window closed → keep engine + bridge up.
        assert!(should_prevent_exit(None));
    }

    #[test]
    fn programmatic_exit_is_allowed() {
        // Some(_) == explicit AppHandle::exit → let the process exit.
        assert!(!should_prevent_exit(Some(0)));
    }

    #[test]
    fn restart_is_allowed() {
        // restart() requests exit with RESTART_EXIT_CODE (i32::MAX); the
        // restart_app command must keep working, so this is not prevented.
        assert!(!should_prevent_exit(Some(i32::MAX)));
    }
}
