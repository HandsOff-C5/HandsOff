//
//  DriverTool.swift
//  DirectorSidecar
//
//  Port of @handsoff/contracts driver-tools.ts — the static enumeration of the
//  cua-driver tool surface (the live driver self-reports 36; the ADR prose's "38"
//  is stale — the driver is the source of truth). This is the validator the loop
//  uses to reject a model-hallucinated tool name before it reaches the driver, and
//  the key the per-tool risk classification (RiskLevel+Policy.swift) is keyed off.
//

import Foundation

extension Contracts {
    /// The cua-driver tool surface. Raw values are the wire tool names (snake_case);
    /// an unknown name fails to decode (the boundary check that keeps a hallucinated
    /// tool out of dispatch — mirrors `safeParseDriverTool`).
    enum DriverTool: String, Codable, Sendable, CaseIterable {
        // session / cursor overlay
        case startSession = "start_session"
        case endSession = "end_session"
        case setAgentCursorEnabled = "set_agent_cursor_enabled"
        case setAgentCursorMotion = "set_agent_cursor_motion"
        case setAgentCursorStyle = "set_agent_cursor_style"
        case getAgentCursorState = "get_agent_cursor_state"
        // perception (read-only)
        case getWindowState = "get_window_state"
        case getAccessibilityTree = "get_accessibility_tree"
        case getCursorPosition = "get_cursor_position"
        case getScreenSize = "get_screen_size"
        case listApps = "list_apps"
        case listWindows = "list_windows"
        case getRecordingState = "get_recording_state"
        case getConfig = "get_config"
        case checkPermissions = "check_permissions"
        case checkForUpdate = "check_for_update"
        case zoom
        // pointer navigation (read-only — no commit)
        case scroll
        case moveCursor = "move_cursor"
        // draft / reversible
        case typeText = "type_text"
        case setValue = "set_value"
        case launchApp = "launch_app"
        case bringToFront = "bring_to_front"
        // mutating (context-dependent for click / key)
        case click
        case rightClick = "right_click"
        case doubleClick = "double_click"
        case drag
        case pressKey = "press_key"
        case hotkey
        case page
        case setConfig = "set_config"
        case startRecording = "start_recording"
        case stopRecording = "stop_recording"
        // destructive / external
        case killApp = "kill_app"
        case replayTrajectory = "replay_trajectory"
        case installFfmpeg = "install_ffmpeg"
        // locally-handled compose surface (U3) — NOT a cua-driver tool. The loop executes it
        // NATIVELY (NoteWriter writes ~/Documents/<title>.md + opens it) instead of forwarding to
        // the driver. Registered here so the resolver's chosen tool name validates through
        // `Contracts.DriverTool.parse` (not blocked as "unknown tool") and risk keys off it; the
        // dispatch interception that short-circuits it away from `driver.call` lives in the loop.
        case writeNote = "write_note"
    }
}

extension Contracts.DriverTool {
    /// Boundary parse for an untrusted tool name (e.g. straight from the model).
    /// Returns nil for a name outside the driver surface — the caller gates it.
    static func parse(_ raw: String) -> Contracts.DriverTool? {
        Contracts.DriverTool(rawValue: raw)
    }
}
