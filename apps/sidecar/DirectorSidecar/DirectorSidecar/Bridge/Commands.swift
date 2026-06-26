//
//  Commands.swift
//  DirectorSidecar
//
//  Swift → engine command frames (director-bridge-contract.md §4.2). The sidecar only
//  *sends* commands; it never re-implements pipeline logic. Each command serializes to the
//  envelope `{ v:1, type:"command", topic, payload }`; the engine acks and forwards to React.
//
//  `commit` (fn-end → execute the resolved intent) is modeled as its OWN topic, distinct
//  from `greenlight` (the optional destructive-only approval). This is the recommended
//  resolution of the open question in §4.2 ("reuse greenlight as the universal go-signal,
//  or add commit?"): commit fires for every risk level on fn-end; greenlight is the narrow
//  destructive gate. Confirm with the engine owner; the engine-side route is co-owned.
//

import Foundation

/// A command the sidecar can send to the engine.
enum Command: Equatable {
    case startListening              // fn activation → stt_ondevice_start
    case commit                      // fn-end → execute the resolved intent
    case stopListening               // abort/cancel → stt_ondevice_stop (do NOT execute)
    case pauseAll                    // interrupt path: pause every running agent
    case pauseSession(String)        // pause a single agent (the agent submenu in the status menu)
    case resumeSession(String)       // resume a paused agent
    case openHome                    // focus/show the main Home Dashboard window
    case selectSession(String)       // Inspector binding (sessionId)
    case greenlight(actionId: String, decidedAt: String)  // optional destructive approval
    case reject(actionId: String, decidedAt: String)

    /// The wire `topic` for this command.
    var topic: String {
        switch self {
        case .startListening: return "startListening"
        case .commit: return "commit"
        case .stopListening: return "stopListening"
        case .pauseAll: return "pauseAll"
        case .pauseSession: return "pauseSession"
        case .resumeSession: return "resumeSession"
        case .openHome: return "openHome"
        case .selectSession: return "selectSession"
        case .greenlight: return "greenlight"
        case .reject: return "reject"
        }
    }

    /// Serialize to the `{ v, type, topic, payload }` command envelope.
    func frameData() throws -> Data {
        let encoder = JSONEncoder()
        switch self {
        case .startListening, .commit, .stopListening, .pauseAll, .openHome:
            return try encoder.encode(Envelope(topic: topic, payload: EmptyPayload()))
        case let .selectSession(sessionId), let .pauseSession(sessionId), let .resumeSession(sessionId):
            return try encoder.encode(Envelope(topic: topic, payload: SelectSessionPayload(sessionId: sessionId)))
        case let .greenlight(actionId, decidedAt):
            return try encoder.encode(Envelope(topic: topic, payload: ApprovalDecisionPayload(
                actionId: actionId, decision: "approved", decidedAt: decidedAt)))
        case let .reject(actionId, decidedAt):
            return try encoder.encode(Envelope(topic: topic, payload: ApprovalDecisionPayload(
                actionId: actionId, decision: "rejected", decidedAt: decidedAt)))
        }
    }
}

private struct Envelope<P: Encodable>: Encodable {
    let v = 1
    let type = "command"
    let topic: String
    let payload: P
}

private struct EmptyPayload: Encodable {}
private struct SelectSessionPayload: Encodable { let sessionId: String }
private struct ApprovalDecisionPayload: Encodable {
    let actionId: String
    let decision: String
    let decidedAt: String
}
