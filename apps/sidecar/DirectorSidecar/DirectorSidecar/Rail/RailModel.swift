//
//  RailModel.swift
//  DirectorSidecar
//
//  The Right-edge rail's state (design: Claude-Design_Director → right-edge-rail-spec.md). The rail
//  is the always-on, minimal edge surface: a LIVE waveform pip (while listening) over a vertical
//  column of running-agent cursor-marks, and an Open-Home affordance. Marks reuse the dashboard's
//  SessionVM (run = gold, needs-greenlight = amber, done = green) so the rail and Home stay in sync.
//

import Foundation
import Observation

@MainActor
@Observable
final class RailModel {
    /// The running-agent roster, mirrored from the `sessions` topic — one cursor-mark per agent.
    private(set) var marks: [SessionVM] = []
    /// The LIVE pip is shown only while Director is actively listening (hold-fn).
    private(set) var isListening = false

    @ObservationIgnored private var connected = false

    /// The rail shows whenever there are agents to summarize, or while listening.
    var isVisible: Bool { !marks.isEmpty || isListening }

    func apply(_ frame: BridgeFrame) {
        switch frame {
        case let .sessions(payload):
            marks = payload.sessions.map(SessionVM.init)
        case let .runResult(result):
            applyRunResult(result)
        case .state, .intent, .cursor, .transcript, .referents, .gaze, .error, .unknown:
            break
        }
    }

    func setListening(_ on: Bool) { isListening = on }

    func setConnection(_ state: ConnectionState) {
        connected = state == .connected
        if !connected { marks = [] } // never strand a roster the engine no longer backs
    }

    private func applyRunResult(_ result: RunResultPayload) {
        guard let id = result.sessionId, let index = marks.firstIndex(where: { $0.id == id }) else { return }
        let existing = marks[index]
        marks[index] = SessionVM(id: existing.id, title: existing.title, agent: existing.agent,
                                 status: result.status, startedAt: existing.startedAt)
    }
}
