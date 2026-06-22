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
    let base = worker_url.trim();
    if !base.starts_with("https://") {
        return Err("invalid-configuration: STT token Worker URL must use https".to_string());
    }
    let token = app_token.trim();
    if token.is_empty() {
        return Err(format!(
            "missing-credentials: {APP_AUTH_TOKEN_ENV} is empty"
        ));
    }
    let separator = if base.contains('?') { "&" } else { "?" };
    Ok((
        format!("{base}{separator}expires_in_seconds={expires_in_seconds}"),
        format!("Bearer {token}"),
    ))
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
    Ok(StreamingToken {
        token: body.token,
        expires_in_seconds: body.expires_in_seconds,
    })
}

/// Mint a single-use AssemblyAI streaming token for the webview.
#[tauri::command]
pub fn stt_mint_token(expires_in_seconds: Option<u32>) -> Result<StreamingToken, String> {
    let worker_url = std::env::var(TOKEN_WORKER_URL_ENV).map_err(|_| {
        format!("missing-configuration: set {TOKEN_WORKER_URL_ENV} to enable live STT")
    })?;
    let app_token = std::env::var(APP_AUTH_TOKEN_ENV)
        .map_err(|_| format!("missing-credentials: set {APP_AUTH_TOKEN_ENV} to enable live STT"))?;
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
    fn defaults_expiry_when_unset() {
        assert_eq!(clamp_expires(None), DEFAULT_EXPIRES_SECONDS);
    }

    #[test]
    fn clamps_expiry_below_and_above_the_valid_range() {
        assert_eq!(clamp_expires(Some(0)), MIN_EXPIRES_SECONDS);
        assert_eq!(clamp_expires(Some(10_000)), MAX_EXPIRES_SECONDS);
    }

    #[test]
    fn missing_worker_url_reports_missing_configuration_without_a_request() {
        // The command reads the env var first and never touches the network when
        // it is absent. We assert the error contract the webview classifies on.
        std::env::remove_var(TOKEN_WORKER_URL_ENV);
        let result = stt_mint_token(Some(60));
        assert!(matches!(result, Err(message) if message.starts_with("missing-configuration")));
    }
}
