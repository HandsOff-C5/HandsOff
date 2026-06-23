// Mints short-lived AssemblyAI v3 streaming tokens for the webview (#31, AD2,
// #82).
//
// NOTE (AD2): the *default* STT provider is macOS on-device recognition — no
// key, no network, no provisioning, targeting all supported Macs. The baseline
// is `SFSpeechRecognizer` (builds on the macOS 15 SDK, runs on macOS 15–26);
// `SpeechAnalyzer` is a macOS-26 fast-path (tracked in #81, needs the 26 SDK).
// AssemblyAI hosted streaming is the DEFERRED provider behind the same `SttStream` seam —
// this command exists for it but is off the critical path for the distributed
// launch. It only runs when the app is configured to use the hosted provider.
//
// The AssemblyAI API key is a provider secret: it must never reach the Tauri
// webview, `local-config.json`, or the shipped Rust app. Browsers also cannot
// set the `Authorization` header on a WebSocket, so the v3 streaming API offers
// a temporary-token flow. This command calls the HandsOff-operated token Worker
// over HTTPS using an app-auth credential, and returns only the single-use
// token. The webview opens the WS with `?token=<token>`.
//
// PROVISIONING (AD2): STT is a provisioned service, not bring-your-own-key.
// The token Worker is the server-side provisioning path. It holds provider
// credentials as Worker secrets, authenticates app instances, and mints
// AssemblyAI temporary tokens. The app-auth token and Worker URL are deployment
// config, not local-config preferences and not webview bundle state. The
// `StreamingToken` contract and the webview WS flow stay identical.
//
// The request construction is split into a pure `build_worker_token_request` so
// its shape (URL, header) is unit-tested without app secrets or the network.

use serde::{Deserialize, Serialize};
use url::Url;

const TOKEN_WORKER_URL_ENV: &str = "HANDSOFF_STT_TOKEN_WORKER_URL";
const APP_AUTH_TOKEN_ENV: &str = "HANDSOFF_STT_APP_AUTH_TOKEN";
const DEFAULT_EXPIRES_SECONDS: u32 = 60;
const MIN_EXPIRES_SECONDS: u32 = 1;
const MAX_EXPIRES_SECONDS: u32 = 600;

// Returned to the webview. `expiresInSeconds` lets the caller decide when to
// re-mint; the token itself is single-use.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct StreamingToken {
    pub token: String,
    pub expires_in_seconds: u32,
}

// Token Worker's response body shape.
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct TokenApiResponse {
    token: String,
    expires_in_seconds: u32,
}

// Clamp the caller-requested TTL into AssemblyAI's documented 1..=600s window.
fn clamp_expires(requested: Option<u32>) -> u32 {
    requested
        .unwrap_or(DEFAULT_EXPIRES_SECONDS)
        .clamp(MIN_EXPIRES_SECONDS, MAX_EXPIRES_SECONDS)
}

// Pure request shape: the full URL and the Authorization header value.
fn build_worker_token_request(
    worker_url: &str,
    app_token: &str,
    expires_in_seconds: u32,
) -> Result<(String, String), String> {
    let mut url = Url::parse(worker_url.trim()).map_err(|_| {
        "invalid-configuration: STT token Worker URL must be a valid URL".to_string()
    })?;
    if url.scheme() != "https" {
        return Err("invalid-configuration: STT token Worker URL must use https".to_string());
    }
    if url.query().is_some() || url.fragment().is_some() {
        return Err(
            "invalid-configuration: STT token Worker URL must not include query or fragment"
                .to_string(),
        );
    }
    let token = app_token.trim();
    if token.is_empty() {
        return Err(format!(
            "missing-credentials: {APP_AUTH_TOKEN_ENV} is empty"
        ));
    }
    url.query_pairs_mut()
        .append_pair("expires_in_seconds", &expires_in_seconds.to_string());
    Ok((url.to_string(), format!("Bearer {token}")))
}

fn validate_worker_token_response(body: TokenApiResponse) -> Result<StreamingToken, String> {
    if body.token.trim().is_empty() {
        return Err("provider-unavailable: Worker returned an empty token".to_string());
    }
    if !(MIN_EXPIRES_SECONDS..=MAX_EXPIRES_SECONDS).contains(&body.expires_in_seconds) {
        return Err("provider-unavailable: Worker returned an invalid token expiry".to_string());
    }
    Ok(StreamingToken {
        token: body.token,
        expires_in_seconds: body.expires_in_seconds,
    })
}

fn mint_token(
    worker_url: &str,
    app_token: &str,
    expires_in_seconds: u32,
) -> Result<StreamingToken, String> {
    let (url, auth) = build_worker_token_request(worker_url, app_token, expires_in_seconds)?;
    let response = ureq::get(&url)
        .set("Authorization", &auth)
        .call()
        .map_err(|error| format!("provider-unavailable: Worker token request failed: {error}"))?;
    let body: TokenApiResponse = response.into_json().map_err(|error| {
        format!("provider-unavailable: could not parse Worker token response: {error}")
    })?;
    validate_worker_token_response(body)
}

/// Mint a single-use AssemblyAI streaming token for the webview.
#[tauri::command]
pub fn stt_mint_token(expires_in_seconds: Option<u32>) -> Result<StreamingToken, String> {
    let worker_url = super::deployment_config(
        TOKEN_WORKER_URL_ENV,
        option_env!("HANDSOFF_STT_TOKEN_WORKER_URL"),
    )
    .ok_or_else(|| {
        format!("missing-configuration: set {TOKEN_WORKER_URL_ENV} to enable live STT")
    })?;
    let app_token = super::deployment_config(
        APP_AUTH_TOKEN_ENV,
        option_env!("HANDSOFF_STT_APP_AUTH_TOKEN"),
    )
    .ok_or_else(|| format!("missing-credentials: set {APP_AUTH_TOKEN_ENV} to enable live STT"))?;
    mint_token(&worker_url, &app_token, clamp_expires(expires_in_seconds))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn builds_the_worker_token_url_and_auth_header() {
        let (url, auth) = build_worker_token_request(
            "https://token.handsoff.test/v1/realtime-token",
            "app-secret",
            60,
        )
        .expect("valid worker request");
        assert_eq!(
            url,
            "https://token.handsoff.test/v1/realtime-token?expires_in_seconds=60"
        );
        assert_eq!(auth, "Bearer app-secret");
    }

    #[test]
    fn rejects_non_https_worker_urls() {
        let result = build_worker_token_request(
            "http://token.handsoff.test/v1/realtime-token",
            "app-secret",
            60,
        );
        assert!(matches!(result, Err(message) if message.contains("https")));
    }

    #[test]
    fn rejects_worker_urls_with_query_or_fragment() {
        let result = build_worker_token_request(
            "https://token.handsoff.test/v1/realtime-token?debug=true",
            "app-secret",
            60,
        );
        assert!(matches!(result, Err(message) if message.contains("query or fragment")));
    }

    #[test]
    fn rejects_empty_worker_tokens() {
        let result = validate_worker_token_response(TokenApiResponse {
            token: " ".to_string(),
            expires_in_seconds: 60,
        });
        assert!(matches!(result, Err(message) if message.contains("empty token")));
    }

    #[test]
    fn rejects_invalid_worker_token_expiry() {
        let result = validate_worker_token_response(TokenApiResponse {
            token: "stream-token".to_string(),
            expires_in_seconds: 0,
        });
        assert!(matches!(result, Err(message) if message.contains("invalid token expiry")));
    }

    #[test]
    fn defaults_expiry_when_unset() {
        assert_eq!(clamp_expires(None), DEFAULT_EXPIRES_SECONDS);
    }

    #[test]
    fn clamps_expiry_below_and_above_the_valid_range() {
        assert_eq!(clamp_expires(Some(0)), MIN_EXPIRES_SECONDS);
        assert_eq!(clamp_expires(Some(10_000)), MAX_EXPIRES_SECONDS);
    }

    #[test]
    fn deployment_config_reports_none_when_env_and_baked_are_absent() {
        // The command resolves config (runtime env first, then the value baked from
        // .env.local at build time) and never touches the network when it is absent.
        std::env::remove_var(TOKEN_WORKER_URL_ENV);
        assert!(super::super::deployment_config(TOKEN_WORKER_URL_ENV, None).is_none());
    }

    #[test]
    fn deployment_config_prefers_runtime_env_over_baked_value() {
        std::env::set_var(
            TOKEN_WORKER_URL_ENV,
            "https://override.handsoff.test/v1/realtime-token",
        );
        let resolved =
            super::super::deployment_config(TOKEN_WORKER_URL_ENV, Some("https://baked.test"));
        std::env::remove_var(TOKEN_WORKER_URL_ENV);
        assert_eq!(
            resolved.as_deref(),
            Some("https://override.handsoff.test/v1/realtime-token")
        );
    }
}
