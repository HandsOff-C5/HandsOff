//
//  BridgeTypes.swift
//  DirectorSidecar
//
//  Wire types for the Director engine bridge. Mirrors @handsoff/contracts readiness +
//  the {v,type,topic,payload} envelope served by src-tauri/src/commands/bridge.rs.
//

import Foundation

struct CapabilityProbe: Codable, Identifiable, Sendable {
    let id: String     // camera | microphone | speech-recognition | cua | accessibility | screen-recording
    let kind: String   // permission | daemon
    let state: String  // granted | denied | not-determined | restricted | unknown | running | stopped | not-installed
}

struct ReadinessPayload: Codable, Sendable {
    let capabilities: [CapabilityProbe]
}

/// A live screen pointer for the agent-cursor / pointing overlay (bridge topic `cursorPosition`).
///
/// `x`/`y` are **global virtual-desktop pixels: origin top-left of the primary display, y grows
/// DOWN** (the space `head-pointing.ts` + `surface.ts` use). macOS AppKit/NSScreen is bottom-left
/// origin, **y UP** — so the overlay MUST flip Y before positioning a window/layer:
///   `let p = NSScreen.screens.first!; cocoaX = x; cocoaY = p.frame.maxY - y`
/// (canonical CG↔Cocoa flip; valid across displays incl. negative offsets).
struct Pointer: Codable, Identifiable, Sendable {
    let x: Double
    let y: Double
    let space: String       // "virtual-desktop-px"
    let kind: String        // "user" | "agent"
    let agentId: String?
    let agentLabel: String?
    let state: String       // "idle" | "moving" | "locked" | "poof"
    let confidence: Double?
    let ts: Double          // epoch ms
    var id: String { agentId ?? kind } // stable per agent; the single user reticle is "user"
}

struct CursorPositionPayload: Codable, Sendable { let pointers: [Pointer] }

/// Decode the bridge frame as an enum on `type` so contract drift fails loudly
/// instead of silently producing empty data.
enum BridgeFrame: Decodable {
    case state(topic: String, readiness: ReadinessPayload?)
    case cursor(pointers: [Pointer])
    case error(reason: String)
    case unknown(type: String)

    private enum Key: String, CodingKey { case v, type, topic, payload }
    private struct ErrorPayload: Decodable { let reason: String }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        guard try c.decode(Int.self, forKey: .v) == 1 else {
            throw DecodingError.dataCorruptedError(forKey: .v, in: c, debugDescription: "unsupported bridge version")
        }
        switch try c.decode(String.self, forKey: .type) {
        case "state":
            let topic = try c.decode(String.self, forKey: .topic)
            switch topic {
            case "readiness":
                self = .state(topic: topic, readiness: try c.decodeIfPresent(ReadinessPayload.self, forKey: .payload))
            case "cursorPosition":
                self = .cursor(pointers: try c.decode(CursorPositionPayload.self, forKey: .payload).pointers)
            default:
                self = .state(topic: topic, readiness: nil)
            }
        case "error":
            self = .error(reason: (try c.decodeIfPresent(ErrorPayload.self, forKey: .payload))?.reason ?? "unknown")
        case let other:
            self = .unknown(type: other)
        }
    }
}
