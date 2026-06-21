// Mints short-lived AssemblyAI v3 streaming tokens for the webview (#31, AD2).
//
// The AssemblyAI API key is a secret: it must never reach the Tauri webview or
// `local-config.json`. Browsers also cannot set the `Authorization` header on a
// WebSocket, so the v3 streaming API offers a temporary-token flow. This command
// keeps the key server-side — read from the `ASSEMBLYAI_API_KEY` environment
// variable — calls `GET https://streaming.assemblyai.com/v3/token`, and returns
// only the single-use token. The webview opens the WS with `?token=<token>`.
//
// The request construction is split into a pure `build_token_request` so its
// shape (URL, header) is unit-tested without a key or the network. The live HTTP
// call is exercised by an `#[ignore]`d integration test that runs only when a
// real key is present, so CI stays green without credentials (and without mocks).

use serde::{Deserialize, Serialize};

const TOKEN_ENDPOINT: &str = "https://streaming.assemblyai.com/v3/token";
const API_KEY_ENV: &str = "ASSEMBLYAI_API_KEY";
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

// AssemblyAI's response body shape.
#[derive(Debug, Deserialize)]
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

// Pure request shape: the full URL and the Authorization header value. Kept
// separate from the HTTP call so it can be asserted without a key or network.
fn build_token_request(base: &str, api_key: &str, expires_in_seconds: u32) -> (String, String) {
    let url = format!("{base}?expires_in_seconds={expires_in_seconds}");
    (url, api_key.to_string())
}

fn mint_token(api_key: &str, expires_in_seconds: u32) -> Result<StreamingToken, String> {
    let (url, auth) = build_token_request(TOKEN_ENDPOINT, api_key, expires_in_seconds);
    let response = ureq::get(&url)
        .set("Authorization", &auth)
        .call()
        .map_err(|error| format!("provider-unavailable: token request failed: {error}"))?;
    let body: TokenApiResponse = response.into_json().map_err(|error| {
        format!("provider-unavailable: could not parse token response: {error}")
    })?;
    Ok(StreamingToken {
        token: body.token,
        expires_in_seconds: body.expires_in_seconds,
    })
}

/// Mint a single-use AssemblyAI streaming token for the webview.
#[tauri::command]
pub fn stt_mint_token(expires_in_seconds: Option<u32>) -> Result<StreamingToken, String> {
    let api_key = std::env::var(API_KEY_ENV)
        .map_err(|_| format!("missing-credentials: set {API_KEY_ENV} to enable live STT"))?;
    if api_key.trim().is_empty() {
        return Err(format!("missing-credentials: {API_KEY_ENV} is empty"));
    }
    mint_token(&api_key, clamp_expires(expires_in_seconds))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn builds_the_token_url_and_auth_header() {
        let (url, auth) = build_token_request(TOKEN_ENDPOINT, "secret-key", 60);
        assert_eq!(
            url,
            "https://streaming.assemblyai.com/v3/token?expires_in_seconds=60"
        );
        assert_eq!(auth, "secret-key");
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
    fn missing_api_key_reports_missing_credentials_without_a_request() {
        // The command reads the env var first and never touches the network when
        // it is absent. We assert the error contract the webview classifies on.
        std::env::remove_var(API_KEY_ENV);
        let result = stt_mint_token(Some(60));
        assert!(matches!(result, Err(message) if message.starts_with("missing-credentials")));
    }

    // Live integration: only runs with a real key (`cargo test -- --ignored`).
    // No mock — exercises the real AssemblyAI endpoint when credentials exist.
    #[test]
    #[ignore = "requires a real ASSEMBLYAI_API_KEY and network access"]
    fn mints_a_real_token_when_credentials_are_present() {
        let key = std::env::var(API_KEY_ENV).expect("ASSEMBLYAI_API_KEY must be set for this test");
        let token = mint_token(&key, 60).expect("a real token should be minted");
        assert!(!token.token.is_empty());
    }
}
