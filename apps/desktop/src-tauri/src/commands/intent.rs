// Proxies OpenAI intent resolution through the HandsOff Worker so provider
// credentials never enter the webview or app bundle.

use serde::{Deserialize, Serialize};
use serde_json::Value;
use url::Url;

const INTENT_WORKER_URL_ENV: &str = "HANDSOFF_INTENT_WORKER_URL";
const APP_AUTH_TOKEN_ENV: &str = "HANDSOFF_INTENT_APP_AUTH_TOKEN";

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct IntentResolveRequest {
    pub model: String,
    pub messages: Value,
}

fn build_worker_intent_request(
    worker_url: &str,
    app_token: &str,
) -> Result<(String, String), String> {
    let url = Url::parse(worker_url.trim())
        .map_err(|_| "invalid-configuration: intent Worker URL must be a valid URL".to_string())?;
    if url.scheme() != "https" {
        return Err("invalid-configuration: intent Worker URL must use https".to_string());
    }
    if url.query().is_some() || url.fragment().is_some() {
        return Err(
            "invalid-configuration: intent Worker URL must not include query or fragment"
                .to_string(),
        );
    }
    let token = app_token.trim();
    if token.is_empty() {
        return Err(format!(
            "missing-credentials: {APP_AUTH_TOKEN_ENV} is empty"
        ));
    }
    Ok((url.to_string(), format!("Bearer {token}")))
}

fn validate_intent_request(request: &IntentResolveRequest) -> Result<(), String> {
    if request.model.trim().is_empty() {
        return Err("invalid-request: model is required".to_string());
    }
    if !request.messages.is_array() {
        return Err("invalid-request: messages must be an array".to_string());
    }
    Ok(())
}

fn validate_worker_response(body: Value) -> Result<Value, String> {
    if body.get("choices").and_then(Value::as_array).is_none() {
        return Err("provider-unavailable: Worker returned invalid intent choices".to_string());
    }
    Ok(body)
}

fn resolve_with_worker(
    worker_url: &str,
    app_token: &str,
    request: IntentResolveRequest,
) -> Result<Value, String> {
    validate_intent_request(&request)?;
    let (url, auth) = build_worker_intent_request(worker_url, app_token)?;
    let response = ureq::post(&url)
        .set("Authorization", &auth)
        .send_json(serde_json::to_value(request).map_err(|error| {
            format!("invalid-request: could not encode intent request: {error}")
        })?)
        .map_err(|error| format!("provider-unavailable: Worker intent request failed: {error}"))?;
    let body: Value = response.into_json().map_err(|error| {
        format!("provider-unavailable: could not parse Worker intent response: {error}")
    })?;
    validate_worker_response(body)
}

#[tauri::command]
pub fn intent_resolve(request: IntentResolveRequest) -> Result<Value, String> {
    let worker_url = super::deployment_config(
        INTENT_WORKER_URL_ENV,
        option_env!("HANDSOFF_INTENT_WORKER_URL"),
    )
    .ok_or_else(|| {
        format!("missing-configuration: set {INTENT_WORKER_URL_ENV} to enable LLM intent")
    })?;
    let app_token = super::deployment_config(
        APP_AUTH_TOKEN_ENV,
        option_env!("HANDSOFF_INTENT_APP_AUTH_TOKEN"),
    )
    .ok_or_else(|| format!("missing-credentials: set {APP_AUTH_TOKEN_ENV} to enable LLM intent"))?;
    resolve_with_worker(&worker_url, &app_token, request)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn request() -> IntentResolveRequest {
        IntentResolveRequest {
            model: "gpt-4o-mini".to_string(),
            messages: serde_json::json!([{ "role": "user", "content": "click there" }]),
        }
    }

    #[test]
    fn builds_the_worker_intent_url_and_auth_header() {
        let (url, auth) = build_worker_intent_request(
            "https://intent.handsoff.test/v1/resolve-intent",
            "app-secret",
        )
        .expect("valid worker request");
        assert_eq!(url, "https://intent.handsoff.test/v1/resolve-intent");
        assert_eq!(auth, "Bearer app-secret");
    }

    #[test]
    fn rejects_non_https_worker_urls() {
        let result = build_worker_intent_request(
            "http://intent.handsoff.test/v1/resolve-intent",
            "app-secret",
        );
        assert!(matches!(result, Err(message) if message.contains("https")));
    }

    #[test]
    fn rejects_worker_urls_with_query_or_fragment() {
        let result = build_worker_intent_request(
            "https://intent.handsoff.test/v1/resolve-intent?debug=true",
            "app-secret",
        );
        assert!(matches!(result, Err(message) if message.contains("query or fragment")));
    }

    #[test]
    fn rejects_empty_worker_tokens() {
        let result =
            build_worker_intent_request("https://intent.handsoff.test/v1/resolve-intent", " ");
        assert!(matches!(result, Err(message) if message.contains("empty")));
    }

    #[test]
    fn rejects_invalid_intent_requests_without_network() {
        let mut invalid = request();
        invalid.messages = serde_json::json!({ "role": "user" });
        let result = validate_intent_request(&invalid);
        assert!(matches!(result, Err(message) if message.contains("messages")));
    }

    #[test]
    fn rejects_worker_responses_without_choices() {
        let result = validate_worker_response(serde_json::json!({ "error": "bad" }));
        assert!(matches!(result, Err(message) if message.contains("choices")));
    }

    #[test]
    fn deployment_config_reports_none_when_env_and_baked_are_absent() {
        std::env::remove_var(INTENT_WORKER_URL_ENV);
        assert!(super::super::deployment_config(INTENT_WORKER_URL_ENV, None).is_none());
        assert!(super::super::deployment_config(INTENT_WORKER_URL_ENV, Some("  ")).is_none());
    }

    #[test]
    fn deployment_config_prefers_runtime_env_over_baked_value() {
        std::env::set_var(
            INTENT_WORKER_URL_ENV,
            "https://override.handsoff.test/v1/resolve-intent",
        );
        let resolved =
            super::super::deployment_config(INTENT_WORKER_URL_ENV, Some("https://baked.test"));
        std::env::remove_var(INTENT_WORKER_URL_ENV);
        assert_eq!(
            resolved.as_deref(),
            Some("https://override.handsoff.test/v1/resolve-intent")
        );
    }

    #[test]
    fn deployment_config_falls_back_to_baked_value_when_env_absent() {
        std::env::remove_var(INTENT_WORKER_URL_ENV);
        assert_eq!(
            super::super::deployment_config(INTENT_WORKER_URL_ENV, Some("https://baked.test")),
            Some("https://baked.test".to_string())
        );
    }
}
