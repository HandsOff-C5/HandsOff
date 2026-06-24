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

/// Decode the bridge frame as an enum on `type` so contract drift fails loudly
/// instead of silently producing empty data.
enum BridgeFrame: Decodable {
    case state(topic: String, readiness: ReadinessPayload?)
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
            let readiness = topic == "readiness"
                ? try c.decodeIfPresent(ReadinessPayload.self, forKey: .payload) : nil
            self = .state(topic: topic, readiness: readiness)
        case "error":
            self = .error(reason: (try c.decodeIfPresent(ErrorPayload.self, forKey: .payload))?.reason ?? "unknown")
        case let other:
            self = .unknown(type: other)
        }
    }
}
