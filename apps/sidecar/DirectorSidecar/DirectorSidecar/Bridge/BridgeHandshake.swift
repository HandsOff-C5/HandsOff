//
//  BridgeHandshake.swift
//  DirectorSidecar
//
//  G1 handshake restore (director-bridge-contract.md §3). On launch the engine writes
//  `~/Library/Application Support/com.handsoff.desktop/bridge.json`:
//  `{ "port": <ephemeral>, "token": "<per-launch-random>", "schema": 1 }`. The sidecar
//  reads it, connects to the port, and sends the token as the first frame.
//
//  Graceful G0 fallback: if the file is absent / malformed / wrong-schema (a G0 engine that
//  never wrote it), fall back to the fixed dev port 51703 with NO token — so the sidecar
//  keeps working against both a G0 engine and a handshake-writing G1 engine. The token is
//  only sent when the engine advertised one (a G0 engine would reject an unknown auth frame).
//
//  NOTE (co-owned, engine): the Rust handshake *writer* (in bridge.rs serve()) and the exact
//  auth-frame shape are the engine half of this task; this is the sidecar reader.
//

import Foundation

/// Where to connect and (optionally) the per-launch auth token.
struct BridgeEndpoint: Equatable, Sendable {
    let host: String
    let port: Int
    let token: String?

    var url: URL { URL(string: "ws://\(host):\(port)")! }
}

enum BridgeHandshake {
    /// G0 fallback: fixed dev port, no token.
    static let fallback = BridgeEndpoint(host: "127.0.0.1", port: 51703, token: nil)

    /// `~/Library/Application Support/com.handsoff.desktop/bridge.json` (engine bundle id).
    static var fileURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support
            .appendingPathComponent("com.handsoff.desktop", isDirectory: true)
            .appendingPathComponent("bridge.json", isDirectory: false)
    }

    /// Pure resolution: handshake bytes (`nil` == file absent) → an endpoint. Malformed,
    /// unreadable, or schema != 1 all degrade to the G0 `fallback` (loopback host always).
    static func resolve(from data: Data?) -> BridgeEndpoint {
        guard
            let data,
            let file = try? JSONDecoder().decode(HandshakeFile.self, from: data),
            file.schema == 1,
            file.port > 0
        else {
            return fallback
        }
        return BridgeEndpoint(host: "127.0.0.1", port: file.port, token: file.token)
    }

    /// Read the handshake file from disk and resolve an endpoint (fallback if absent).
    static func load() -> BridgeEndpoint {
        resolve(from: try? Data(contentsOf: fileURL))
    }

    private struct HandshakeFile: Decodable {
        let port: Int
        let token: String
        let schema: Int
    }
}

/// Live connection state for the menu / HUD chrome (director-ui-tasks-track-s.md § G1 state model).
enum ConnectionState: Equatable, Sendable {
    case connecting
    case connected
    case reconnecting
    case engineDown
}
