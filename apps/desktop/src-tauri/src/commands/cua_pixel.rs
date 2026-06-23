// Pixel-coordinate computer-use commands the brain loop's environment names
// (packages/cua/src/runner/computer-env.ts → computerActionToDriverCall). These
// are the contract between Claude's computer_20251124 pixel actions and the
// (Mac-side) trycua/cua-driver sidecar.
//
// STATUS: STUBS — every command returns `not-implemented`. They compile and are
// registered so the TS env wiring is complete and a missing implementation is a
// clear error fed back to the brain (not a "command not found" panic). Implement
// each against the installed cua-driver pixel CLI in CUA-0; verify pixels on the
// target Mac (Retina logical-points vs pixels — research §Q6).
//
// Command → args (from the TS env) → expected return:
//   cua_screenshot      { region?: [x1,y1,x2,y2] }                 -> base64 PNG (String)
//   cua_cursor_position { }                                        -> { x, y } (Value)
//   cua_pointer_move    { x, y }                                   -> ()
//   cua_pointer_click   { button, clicks, x, y, modifier? }        -> ()
//   cua_pointer_drag    { fromX, fromY, toX, toY }                 -> ()
//   cua_pointer_button  { state: "down"|"up", x?, y? }             -> ()
//   cua_scroll          { x, y, direction, amount, modifier? }     -> ()
//   cua_type            { text }                                   -> ()
//   cua_key             { keys }                                   -> ()
//   cua_hold_key        { keys, durationMs }                       -> ()

use serde_json::Value;

const NOT_IMPLEMENTED: &str = "not-implemented";

fn pending(command: &str) -> String {
    format!("{NOT_IMPLEMENTED}: {command} needs the trycua/cua-driver pixel CLI (CUA-0)")
}

#[tauri::command]
pub fn cua_screenshot(_region: Option<Value>) -> Result<String, String> {
    Err(pending("cua_screenshot"))
}

#[tauri::command]
pub fn cua_cursor_position() -> Result<Value, String> {
    Err(pending("cua_cursor_position"))
}

#[tauri::command]
pub fn cua_pointer_move(_x: i64, _y: i64) -> Result<(), String> {
    Err(pending("cua_pointer_move"))
}

#[tauri::command]
pub fn cua_pointer_click(
    _button: String,
    _clicks: u32,
    _x: i64,
    _y: i64,
    _modifier: Option<String>,
) -> Result<(), String> {
    Err(pending("cua_pointer_click"))
}

#[tauri::command]
pub fn cua_pointer_drag(_from_x: i64, _from_y: i64, _to_x: i64, _to_y: i64) -> Result<(), String> {
    Err(pending("cua_pointer_drag"))
}

#[tauri::command]
pub fn cua_pointer_button(_state: String, _x: Option<i64>, _y: Option<i64>) -> Result<(), String> {
    Err(pending("cua_pointer_button"))
}

#[tauri::command]
pub fn cua_scroll(
    _x: i64,
    _y: i64,
    _direction: String,
    _amount: u32,
    _modifier: Option<String>,
) -> Result<(), String> {
    Err(pending("cua_scroll"))
}

#[tauri::command]
pub fn cua_type(_text: String) -> Result<(), String> {
    Err(pending("cua_type"))
}

#[tauri::command]
pub fn cua_key(_keys: String) -> Result<(), String> {
    Err(pending("cua_key"))
}

#[tauri::command]
pub fn cua_hold_key(_keys: String, _duration_ms: u64) -> Result<(), String> {
    Err(pending("cua_hold_key"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pending_message_names_the_command_and_driver() {
        let message = pending("cua_pointer_click");
        assert!(message.starts_with(NOT_IMPLEMENTED));
        assert!(message.contains("cua_pointer_click"));
        assert!(message.contains("cua-driver"));
    }

    #[test]
    fn stubs_report_not_implemented() {
        assert!(
            matches!(cua_type("hi".to_string()), Err(message) if message.starts_with(NOT_IMPLEMENTED))
        );
        assert!(
            matches!(cua_cursor_position(), Err(message) if message.starts_with(NOT_IMPLEMENTED))
        );
    }
}
