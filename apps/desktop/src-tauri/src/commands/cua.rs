use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::process::Command;

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CuaPermissionReport {
    pub accessibility: &'static str,
    pub screen_recording: &'static str,
    pub driver: &'static str,
}

#[derive(Debug, Deserialize)]
struct DriverPermissionReport {
    accessibility: bool,
    screen_recording: bool,
}

#[derive(Debug, Deserialize)]
struct DriverAppList {
    apps: Vec<DriverApp>,
}

#[derive(Debug, Deserialize)]
struct DriverApp {
    active: bool,
    bundle_id: Option<String>,
    name: String,
    pid: u32,
    running: bool,
}

#[derive(Debug, Deserialize)]
struct DriverWindowList {
    windows: Vec<DriverWindow>,
}

#[derive(Debug, Deserialize)]
struct DriverWindow {
    app_name: String,
    title: String,
    pid: u32,
    window_id: u32,
    is_on_screen: bool,
    z_index: i64,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CuaWindow {
    pub id: String,
    pub title: String,
    pub app: String,
    pub pid: u32,
    pub window_id: u32,
    pub availability: &'static str,
    pub access_status: &'static str,
    pub focused: bool,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CuaApp {
    pub id: String,
    pub name: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub pid: Option<u32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub bundle_id: Option<String>,
    pub running: bool,
    pub active: bool,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CuaWindowState {
    pub surface: CuaWindow,
    pub element_count: u64,
    pub elements: Vec<Value>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CuaScreenshot {
    pub surface: CuaWindow,
    pub mime_type: String,
    pub width: u64,
    pub height: u64,
    pub png_base64: String,
}

#[derive(Debug, Serialize)]
pub struct CuaActionResult {
    pub status: &'static str,
    pub summary: String,
}

fn run_cua(args: &[&str]) -> Result<Value, String> {
    let output = Command::new("cua-driver")
        .args(args)
        .output()
        .map_err(|error| format!("cua-driver failed to start: {error}"))?;

    ensure_success(output.status.success(), &output.stderr)?;
    parse_json_stdout(&output.stdout)
}

fn run_cua_action(args: &[&str]) -> Result<(), String> {
    let output = Command::new("cua-driver")
        .args(args)
        .output()
        .map_err(|error| format!("cua-driver failed to start: {error}"))?;

    ensure_success(output.status.success(), &output.stderr)
}

fn ensure_success(success: bool, stderr: &[u8]) -> Result<(), String> {
    if success {
        return Ok(());
    }
    Err(format!(
        "cua-driver failed: {}",
        String::from_utf8_lossy(stderr)
    ))
}

fn parse_json_stdout(stdout: &[u8]) -> Result<Value, String> {
    serde_json::from_slice(stdout)
        .map_err(|error| format!("cua-driver returned invalid JSON: {error}"))
}

fn call_tool(tool: &str, input: Value) -> Result<Value, String> {
    run_cua(&["call", tool, &input.to_string()])
}

fn call_action_tool(tool: &str, input: Value) -> Result<(), String> {
    run_cua_action(&["call", tool, &input.to_string()])
}

fn call_action_tool_json(tool: &str, input: Value) -> Result<Value, String> {
    run_cua(&["call", tool, &input.to_string()])
}

fn launch_app_input(app_name: String, bundle_id: Option<String>) -> Value {
    let mut input = json!({ "name": app_name });
    if let Some(bundle_id) = bundle_id {
        input["bundle_id"] = json!(bundle_id);
    }
    input
}

fn map_window(window: DriverWindow, focused: bool) -> CuaWindow {
    CuaWindow {
        id: format!("{}:{}", window.pid, window.window_id),
        title: if window.title.is_empty() {
            window.app_name.clone()
        } else {
            window.title
        },
        app: window.app_name,
        pid: window.pid,
        window_id: window.window_id,
        availability: if window.is_on_screen {
            "available"
        } else {
            "unknown"
        },
        access_status: "accessible",
        focused,
    }
}

fn map_app(app: DriverApp) -> CuaApp {
    let id = app
        .bundle_id
        .clone()
        .unwrap_or_else(|| app.name.to_ascii_lowercase());
    CuaApp {
        id,
        name: app.name,
        pid: if app.pid > 0 { Some(app.pid) } else { None },
        bundle_id: app.bundle_id,
        running: app.running,
        active: app.active,
    }
}

fn map_permissions(report: DriverPermissionReport) -> CuaPermissionReport {
    CuaPermissionReport {
        accessibility: if report.accessibility {
            "granted"
        } else {
            "denied"
        },
        screen_recording: if report.screen_recording {
            "granted"
        } else {
            "denied"
        },
        driver: "running",
    }
}

fn element_count(raw: &Value) -> u64 {
    raw.get("element_count")
        .and_then(Value::as_u64)
        .unwrap_or(0)
}

fn map_elements(_raw: &Value) -> Vec<Value> {
    vec![]
}

fn screenshot_field_u64(raw: &Value, field: &str) -> Result<u64, String> {
    raw.get(field)
        .and_then(Value::as_u64)
        .ok_or_else(|| format!("CUA screenshot missing {field}"))
}

fn screenshot_field_string(raw: &Value, field: &str) -> Result<String, String> {
    raw.get(field)
        .and_then(Value::as_str)
        .map(ToString::to_string)
        .ok_or_else(|| format!("CUA screenshot missing {field}"))
}

#[tauri::command]
pub fn cua_permissions() -> CuaPermissionReport {
    match run_cua(&["permissions", "status", "--json"]).and_then(|value| {
        serde_json::from_value::<DriverPermissionReport>(value).map_err(|error| error.to_string())
    }) {
        Ok(report) => map_permissions(report),
        Err(_) => CuaPermissionReport {
            accessibility: "unknown",
            screen_recording: "unknown",
            driver: "unavailable",
        },
    }
}

#[tauri::command]
pub fn cua_list_apps() -> Result<Vec<CuaApp>, String> {
    let list = serde_json::from_value::<DriverAppList>(call_tool("list_apps", json!({}))?)
        .map_err(|error| format!("Could not parse CUA apps: {error}"))?;
    Ok(list.apps.into_iter().map(map_app).collect())
}

#[tauri::command]
pub fn cua_list_windows() -> Result<Vec<CuaWindow>, String> {
    let list = serde_json::from_value::<DriverWindowList>(call_tool(
        "list_windows",
        json!({ "on_screen_only": true }),
    )?)
    .map_err(|error| format!("Could not parse CUA windows: {error}"))?;
    let frontmost = list.windows.iter().map(|window| window.z_index).max();

    Ok(list
        .windows
        .into_iter()
        .map(|window| {
            let focused = Some(window.z_index) == frontmost;
            map_window(window, focused)
        })
        .collect())
}

#[tauri::command]
pub fn cua_screenshot(pid: u32, window_id: u32) -> Result<CuaScreenshot, String> {
    let raw = call_tool(
        "get_window_state",
        json!({ "pid": pid, "window_id": window_id, "capture_mode": "vision" }),
    )?;
    let surface = cua_list_windows()?
        .into_iter()
        .find(|window| window.pid == pid && window.window_id == window_id)
        .ok_or_else(|| "CUA window disappeared before screenshot capture".to_string())?;

    Ok(CuaScreenshot {
        surface,
        mime_type: screenshot_field_string(&raw, "screenshot_mime_type")?,
        width: screenshot_field_u64(&raw, "screenshot_width")?,
        height: screenshot_field_u64(&raw, "screenshot_height")?,
        png_base64: screenshot_field_string(&raw, "screenshot_png_b64")?,
    })
}

#[tauri::command]
pub fn cua_get_window_state(pid: u32, window_id: u32) -> Result<CuaWindowState, String> {
    let raw = call_tool(
        "get_window_state",
        json!({ "pid": pid, "window_id": window_id, "capture_mode": "ax" }),
    )?;
    let elements = map_elements(&raw);
    let window = cua_list_windows()?
        .into_iter()
        .find(|window| window.pid == pid && window.window_id == window_id)
        .ok_or_else(|| "CUA window disappeared before state capture".to_string())?;

    Ok(CuaWindowState {
        surface: window,
        element_count: element_count(&raw),
        elements,
    })
}

#[tauri::command]
pub fn cua_launch_app(
    app_name: String,
    bundle_id: Option<String>,
) -> Result<CuaActionResult, String> {
    call_action_tool_json("launch_app", launch_app_input(app_name, bundle_id))?;
    Ok(CuaActionResult {
        status: "succeeded",
        summary: "Launched requested app".to_string(),
    })
}

#[tauri::command]
pub fn cua_click(
    pid: u32,
    window_id: u32,
    element_index: Option<u32>,
) -> Result<CuaActionResult, String> {
    let mut input = json!({ "pid": pid, "window_id": window_id });
    if let Some(idx) = element_index {
        input["element_index"] = json!(idx);
    }
    call_action_tool("click", input)?;
    Ok(CuaActionResult {
        status: "succeeded",
        summary: "Clicked selected target".to_string(),
    })
}

#[tauri::command]
pub fn cua_type_text(
    pid: u32,
    window_id: u32,
    element_index: Option<u32>,
    text: String,
) -> Result<CuaActionResult, String> {
    // element_index is optional — without it, the cua-driver types into the pid's
    // currently focused element (no prior get_window_state needed).
    let mut input = json!({ "pid": pid, "window_id": window_id, "text": text });
    if let Some(idx) = element_index {
        input["element_index"] = json!(idx);
    }
    call_action_tool("type_text", input)?;
    Ok(CuaActionResult {
        status: "succeeded",
        summary: "Typed dictated text".to_string(),
    })
}

#[tauri::command]
pub fn cua_set_value(
    pid: u32,
    window_id: u32,
    element_index: Option<u32>,
    value: String,
) -> Result<CuaActionResult, String> {
    let mut input = json!({ "pid": pid, "window_id": window_id, "value": value });
    if let Some(idx) = element_index {
        input["element_index"] = json!(idx);
    }
    call_action_tool("set_value", input)?;
    Ok(CuaActionResult {
        status: "succeeded",
        summary: "Set selected value".to_string(),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn maps_permission_booleans_to_contract_states() {
        let report = map_permissions(DriverPermissionReport {
            accessibility: true,
            screen_recording: false,
        });

        assert_eq!(report.accessibility, "granted");
        assert_eq!(report.screen_recording, "denied");
        assert_eq!(report.driver, "running");
    }

    #[test]
    fn maps_driver_windows_to_contract_surfaces() {
        let window = map_window(
            DriverWindow {
                app_name: "Notes".to_string(),
                title: "".to_string(),
                pid: 42,
                window_id: 7,
                is_on_screen: true,
                z_index: 10,
            },
            true,
        );

        assert_eq!(window.id, "42:7");
        assert_eq!(window.title, "Notes");
        assert_eq!(window.app, "Notes");
        assert_eq!(window.availability, "available");
        assert_eq!(window.access_status, "accessible");
        assert!(window.focused);
    }

    #[test]
    fn maps_driver_apps_to_contract_apps() {
        let running = map_app(DriverApp {
            active: true,
            bundle_id: Some("com.apple.Notes".to_string()),
            name: "Notes".to_string(),
            pid: 42,
            running: true,
        });
        let installed = map_app(DriverApp {
            active: false,
            bundle_id: None,
            name: "Preview".to_string(),
            pid: 0,
            running: false,
        });

        assert_eq!(running.id, "com.apple.Notes");
        assert_eq!(running.pid, Some(42));
        assert!(running.running);
        assert_eq!(installed.id, "preview");
        assert_eq!(installed.pid, None);
    }

    #[test]
    fn validates_screenshot_fields_loudly() {
        let raw = json!({
            "screenshot_mime_type": "image/png",
            "screenshot_width": 640,
            "screenshot_height": 480,
            "screenshot_png_b64": "abc123"
        });

        assert_eq!(
            screenshot_field_string(&raw, "screenshot_mime_type").unwrap(),
            "image/png"
        );
        assert_eq!(screenshot_field_u64(&raw, "screenshot_width").unwrap(), 640);
        assert!(screenshot_field_string(&json!({}), "screenshot_png_b64").is_err());
    }

    #[test]
    fn preserves_driver_element_count_without_fabricating_elements() {
        let elements = map_elements(&json!({ "element_count": 3 }));

        assert_eq!(element_count(&json!({ "element_count": 3 })), 3);
        assert!(elements.is_empty());
        assert!(map_elements(&json!({ "element_count": 0 })).is_empty());
    }

    #[test]
    fn encodes_launch_app_input_with_optional_bundle_id() {
        assert_eq!(
            launch_app_input(
                "TextEdit".to_string(),
                Some("com.apple.TextEdit".to_string())
            ),
            json!({ "name": "TextEdit", "bundle_id": "com.apple.TextEdit" })
        );
        assert_eq!(
            launch_app_input("TextEdit".to_string(), None),
            json!({ "name": "TextEdit" })
        );
    }

    #[test]
    fn action_success_does_not_require_json_stdout() {
        assert!(ensure_success(true, b"Inserted text").is_ok());
    }

    #[test]
    fn json_output_still_requires_valid_json() {
        assert!(parse_json_stdout(br#"{"ok":true}"#).is_ok());
        assert!(parse_json_stdout(b"Inserted text").is_err());
    }
}
