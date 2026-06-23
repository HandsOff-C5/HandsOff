// One step of the Claude computer-use brain loop. The TS side
// (createTauriComputerUseClient → createAnthropicBrain) builds the request and
// invokes this command; the Anthropic key stays here on the Rust side, never in
// the webview. Mirrors `intent_resolve`, but per the decided CUA architecture the
// demo calls Anthropic directly with a local ANTHROPIC_API_KEY (harden to a
// Worker later — see docs/RESEARCH-CUA.md). Returns the raw message, which the
// TS parseBrainStep validates.

use serde::Deserialize;
use serde_json::{json, Value};

const ANTHROPIC_API_KEY_ENV: &str = "ANTHROPIC_API_KEY";
const ANTHROPIC_MESSAGES_URL: &str = "https://api.anthropic.com/v1/messages";
const ANTHROPIC_VERSION: &str = "2023-06-01";

// Mirrors the TS ComputerUseRequest (wire field names, snake_case max_tokens).
#[derive(Debug, Clone, Deserialize)]
pub struct CuaBrainRequest {
    pub model: String,
    #[serde(default)]
    pub betas: Vec<String>,
    pub tools: Value,
    pub messages: Value,
    pub max_tokens: u32,
}

fn validate_brain_request(request: &CuaBrainRequest) -> Result<(), String> {
    if request.model.trim().is_empty() {
        return Err("invalid-request: model is required".to_string());
    }
    if !request.messages.is_array() {
        return Err("invalid-request: messages must be an array".to_string());
    }
    if !request.tools.is_array() {
        return Err("invalid-request: tools must be an array".to_string());
    }
    if request.max_tokens == 0 {
        return Err("invalid-request: max_tokens must be greater than zero".to_string());
    }
    Ok(())
}

// Anthropic accepts a comma-joined list of beta names in the anthropic-beta header.
fn anthropic_beta_header(betas: &[String]) -> String {
    betas
        .iter()
        .map(|beta| beta.trim())
        .filter(|beta| !beta.is_empty())
        .collect::<Vec<_>>()
        .join(",")
}

fn build_messages_body(request: &CuaBrainRequest) -> Value {
    json!({
        "model": request.model,
        "max_tokens": request.max_tokens,
        "tools": request.tools,
        "messages": request.messages,
    })
}

fn call_anthropic(api_key: &str, request: CuaBrainRequest) -> Result<Value, String> {
    validate_brain_request(&request)?;
    let beta = anthropic_beta_header(&request.betas);
    let body = build_messages_body(&request);

    let mut http = ureq::post(ANTHROPIC_MESSAGES_URL)
        .set("x-api-key", api_key)
        .set("anthropic-version", ANTHROPIC_VERSION);
    if !beta.is_empty() {
        http = http.set("anthropic-beta", &beta);
    }

    let response = http
        .send_json(body)
        .map_err(|error| format!("provider-unavailable: Anthropic request failed: {error}"))?;
    response.into_json().map_err(|error| {
        format!("provider-unavailable: could not parse Anthropic response: {error}")
    })
}

#[tauri::command]
pub fn cua_brain_step(request: CuaBrainRequest) -> Result<Value, String> {
    let api_key = std::env::var(ANTHROPIC_API_KEY_ENV).map_err(|_| {
        format!("missing-credentials: set {ANTHROPIC_API_KEY_ENV} to enable the CUA brain")
    })?;
    call_anthropic(&api_key, request)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn request() -> CuaBrainRequest {
        CuaBrainRequest {
            model: "claude-opus-4-8".to_string(),
            betas: vec!["computer-use-2025-11-24".to_string()],
            tools: json!([{ "type": "computer_20251124", "name": "computer" }]),
            messages: json!([{ "role": "user", "content": "open Cursor" }]),
            max_tokens: 1024,
        }
    }

    #[test]
    fn accepts_a_well_formed_request() {
        assert!(validate_brain_request(&request()).is_ok());
    }

    #[test]
    fn rejects_empty_model() {
        let mut invalid = request();
        invalid.model = "  ".to_string();
        assert!(
            matches!(validate_brain_request(&invalid), Err(message) if message.contains("model"))
        );
    }

    #[test]
    fn rejects_non_array_messages() {
        let mut invalid = request();
        invalid.messages = json!({ "role": "user" });
        assert!(
            matches!(validate_brain_request(&invalid), Err(message) if message.contains("messages"))
        );
    }

    #[test]
    fn rejects_non_array_tools() {
        let mut invalid = request();
        invalid.tools = json!({ "type": "computer_20251124" });
        assert!(
            matches!(validate_brain_request(&invalid), Err(message) if message.contains("tools"))
        );
    }

    #[test]
    fn rejects_zero_max_tokens() {
        let mut invalid = request();
        invalid.max_tokens = 0;
        assert!(
            matches!(validate_brain_request(&invalid), Err(message) if message.contains("max_tokens"))
        );
    }

    #[test]
    fn joins_beta_names_and_drops_blanks() {
        let betas = vec![
            "computer-use-2025-11-24".to_string(),
            " ".to_string(),
            "extra-beta".to_string(),
        ];
        assert_eq!(
            anthropic_beta_header(&betas),
            "computer-use-2025-11-24,extra-beta"
        );
    }

    #[test]
    fn builds_the_messages_body_passing_tools_and_messages_through() {
        let body = build_messages_body(&request());
        assert_eq!(body["model"], json!("claude-opus-4-8"));
        assert_eq!(body["max_tokens"], json!(1024));
        assert!(body["tools"].is_array());
        assert!(body["messages"].is_array());
    }

    #[test]
    fn missing_api_key_reports_missing_credentials_without_a_request() {
        std::env::remove_var(ANTHROPIC_API_KEY_ENV);
        let result = cua_brain_step(request());
        assert!(matches!(result, Err(message) if message.starts_with("missing-credentials")));
    }
}
