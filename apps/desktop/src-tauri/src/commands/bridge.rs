// Director engine bridge — Gate G0 (loopback WebSocket server for the native Swift sidecar).
//
// A read-only loopback WS server hosted inside the Tauri process. The Swift sidecar
// (DirectorSidecar) connects to ws://127.0.0.1:51703, sends a `getReadiness` command
// frame, and receives the SAME macOS capability readiness the dashboard IPC serves
// (via `readiness_payload()`). No write verbs exist yet; the per-launch bearer token and
// the move to a Unix-domain socket land BEFORE the first command verb at G1/G2 — see
// HandsOff-Knowledge/docs/director-bridge-contract.md.
//
// Hardened per adversarial review (workflow g0-bridge-hardening, 2026-06-24):
//   - direct `tokio` dep (net,rt); `tokio-tungstenite` pinned =0.24 (Message::Text is String);
//   - resilient accept loop — one transient accept error never kills the bridge;
//   - loud bind-failure logging — a dead-on-arrival bridge would silently fail the gate;
//   - bind the 127.0.0.1 literal + reject any upgrade carrying an `Origin` (browsers) or a
//     non-loopback `Host` (DNS-rebinding), since WebSockets bypass SOP/CORS.

use crate::commands::readiness::readiness_payload;
use futures_util::{SinkExt, StreamExt};
use serde_json::{json, Value};
use tokio::net::TcpStream;
use tokio_tungstenite::accept_hdr_async;
use tokio_tungstenite::tungstenite::handshake::server::{ErrorResponse, Request, Response};
use tokio_tungstenite::tungstenite::http::{Response as HttpResponse, StatusCode};
use tokio_tungstenite::tungstenite::Message;

const HOST: &str = "127.0.0.1";
const PORT: u16 = 51703;

/// Parse one inbound text frame and produce the response frame as a JSON string.
/// Pure (no I/O) so it is unit-testable. `getReadiness` is the only reachable topic;
/// bad JSON, an unsupported version, or any other topic returns a typed error frame.
pub fn handle_bridge_text(input: &str) -> String {
    let Ok(msg) = serde_json::from_str::<Value>(input) else {
        return error_frame("malformed-json");
    };
    if msg.get("v").and_then(Value::as_i64) != Some(1) {
        return error_frame("unsupported-version");
    }
    match (
        msg.get("type").and_then(Value::as_str),
        msg.get("topic").and_then(Value::as_str),
    ) {
        (Some("command"), Some("getReadiness")) => state_frame("readiness", readiness_payload()),
        _ => error_frame("unknown-topic"),
    }
}

fn state_frame(topic: &str, payload: Value) -> String {
    json!({ "v": 1, "type": "state", "topic": topic, "payload": payload }).to_string()
}

fn error_frame(reason: &str) -> String {
    json!({ "v": 1, "type": "error", "topic": "error", "payload": { "reason": reason } })
        .to_string()
}

/// Reject any upgrade carrying an `Origin` (every browser sends one; the native
/// `URLSessionWebSocketTask` sends none) or a non-loopback `Host` (DNS-rebinding).
// The `Result<Response, ErrorResponse>` shape is mandated by tokio-tungstenite's
// `Callback` trait, so the large `Err` variant is not ours to box away.
#[allow(clippy::result_large_err)]
fn gate_upgrade(req: &Request, res: Response) -> Result<Response, ErrorResponse> {
    if req.headers().contains_key("origin") {
        return Err(forbidden("origin-not-allowed"));
    }
    let expected = format!("{HOST}:{PORT}");
    let host = req.headers().get("host").and_then(|h| h.to_str().ok());
    if host == Some(expected.as_str()) {
        Ok(res)
    } else {
        Err(forbidden("bad-host"))
    }
}

fn forbidden(reason: &'static str) -> ErrorResponse {
    HttpResponse::builder()
        .status(StatusCode::FORBIDDEN)
        .body(Some(reason.to_string()))
        .expect("a static FORBIDDEN response always builds")
}

async fn handle_conn(stream: TcpStream) {
    let ws = match accept_hdr_async(stream, gate_upgrade).await {
        Ok(ws) => ws,
        Err(_) => return, // rejected upgrade or handshake failure — drop quietly
    };
    let (mut tx, mut rx) = ws.split();
    while let Some(Ok(msg)) = rx.next().await {
        if let Message::Text(text) = msg {
            if tx
                .send(Message::Text(handle_bridge_text(&text)))
                .await
                .is_err()
            {
                break;
            }
        }
    }
}

/// Run the loopback bridge server. Spawned from `main.rs` `.setup()`; never returns
/// under normal operation. A bind failure (e.g. a stale instance still holding 51703)
/// logs loudly and ends the task, so the gate test fails fast and visibly instead of a
/// sidecar that hangs forever waiting to connect.
pub async fn serve() {
    let addr = std::net::SocketAddr::from(([127, 0, 0, 1], PORT));
    let listener = match tokio::net::TcpListener::bind(addr).await {
        Ok(listener) => listener,
        Err(e) => {
            eprintln!(
                "director-bridge: FAILED to bind {HOST}:{PORT} ({e}) — sidecar cannot connect"
            );
            return;
        }
    };
    if let Ok(local) = listener.local_addr() {
        debug_assert!(
            local.ip().is_loopback(),
            "bridge must bind a loopback address"
        );
        eprintln!("director-bridge: listening on {local}");
    }
    loop {
        match listener.accept().await {
            Ok((stream, _peer)) => {
                tauri::async_runtime::spawn(handle_conn(stream));
            }
            // A transient accept error (EMFILE, connection aborted) must never kill the bridge.
            Err(e) => eprintln!("director-bridge: accept error (continuing): {e}"),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn parse(s: String) -> Value {
        serde_json::from_str(&s).expect("bridge response is valid JSON")
    }

    #[test]
    fn get_readiness_returns_a_state_frame_with_six_capabilities() {
        let v = parse(handle_bridge_text(
            r#"{"v":1,"type":"command","topic":"getReadiness"}"#,
        ));
        assert_eq!(v["type"], "state");
        assert_eq!(v["topic"], "readiness");
        assert_eq!(v["payload"]["capabilities"].as_array().unwrap().len(), 6);
    }

    #[test]
    fn malformed_json_returns_an_error_frame() {
        assert_eq!(parse(handle_bridge_text("not json"))["type"], "error");
    }

    #[test]
    fn wrong_protocol_version_returns_an_error_frame() {
        let v = parse(handle_bridge_text(
            r#"{"v":2,"type":"command","topic":"getReadiness"}"#,
        ));
        assert_eq!(v["type"], "error");
    }

    #[test]
    fn unknown_topic_returns_an_error_frame() {
        let v = parse(handle_bridge_text(
            r#"{"v":1,"type":"command","topic":"whoami"}"#,
        ));
        assert_eq!(v["type"], "error");
    }
}
