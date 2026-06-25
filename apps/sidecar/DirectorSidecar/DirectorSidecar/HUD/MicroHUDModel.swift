//
//  MicroHUDModel.swift
//  DirectorSidecar
//
//  G3 screen-edge micro-HUD state — the calm, collapsed sibling of the full HUD. Three triggers
//  (## Activation state machine): (1) ACTIVE listening → ambient pill; (2) IDLE edge-hover reveal
//  → clickable "Open Home"; (3) AGENT-WORKING → persists while an agent runs. It collapses + yields
//  to the full HUD the moment real loop content arrives. Phase derivation + edge geometry are pure.
//

import Foundation
import CoreGraphics
import Observation

enum ScreenEdge: Sendable {
    case leading
    case trailing

    /// UserDefaults `director.listenEdge` ("left"/"right"), default trailing (onboarding off-stage).
    nonisolated static var configured: ScreenEdge {
        UserDefaults.standard.string(forKey: "director.listenEdge") == "left" ? .leading : .trailing
    }
}

enum MicroHUDPhase: Equatable, Sendable {
    case hidden
    case edgeHoverReveal   // inactive + cursor at edge → clickable Open-Home affordance
    case ambientIdle       // fn active, no agents — "Director is hearing you"
    case ambientActive     // fn active + ≥1 running agent (agent row)
    case agentWorking      // post-commit: persists while an agent runs, cursor docked
    case error
}

@MainActor
@Observable
final class MicroHUDModel {
    private(set) var phase: MicroHUDPhase = .hidden
    private(set) var runningSessions: [MenuSession] = []
    private(set) var audioLevel: Double = 0.3 // 0…1, ambient shimmer floor; bumps on transcript

    let listenEdge: ScreenEdge

    // Inputs that drive the phase (kept private; mutated via setters/apply).
    @ObservationIgnored private var listening = false
    @ObservationIgnored private var fullHUDActive = false
    @ObservationIgnored private var cursorAtEdge = false
    @ObservationIgnored private var connected = true

    init(listenEdge: ScreenEdge = .configured) {
        self.listenEdge = listenEdge
    }

    var isVisible: Bool { phase != .hidden }

    // MARK: inputs

    func setListening(_ on: Bool) {
        listening = on
        if !on { audioLevel = 0.3 }
        recompute()
    }

    /// The full HUD owns the screen once real content arrives; the micro yields (hidden).
    func setFullHUDActive(_ on: Bool) {
        fullHUDActive = on
        recompute()
    }

    func setCursorAtEdge(_ on: Bool) {
        cursorAtEdge = on
        recompute()
    }

    func apply(_ frame: BridgeFrame) {
        switch frame {
        case .transcript:
            audioLevel = 0.9 // partial cadence → waveform liveliness proxy (no raw mic level)
            recompute()
        case let .sessions(payload):
            runningSessions = payload.sessions.map(MenuSession.init).filter { $0.status == .running }
            recompute()
        case let .runResult(result):
            if result.status != .running, result.status != .queued {
                runningSessions.removeAll { $0.id == result.sessionId }
            }
            recompute()
        case .state, .referents, .intent, .cursor, .gaze, .error, .unknown:
            break
        }
    }

    func setConnection(_ state: ConnectionState) {
        connected = state == .connected
        if !connected { phase = .hidden } // never a broken pill — hide on disconnect
        else { recompute() }
    }

    private func recompute() {
        phase = Self.derivePhase(
            connected: connected, listening: listening, fullHUDActive: fullHUDActive,
            cursorAtEdge: cursorAtEdge, agentRunning: !runningSessions.isEmpty
        )
    }

    // MARK: pure derivations (unit-tested)

    nonisolated static func derivePhase(
        connected: Bool, listening: Bool, fullHUDActive: Bool,
        cursorAtEdge: Bool, agentRunning: Bool
    ) -> MicroHUDPhase {
        guard connected else { return .hidden }
        if fullHUDActive { return .hidden }          // full HUD owns the screen
        if listening { return agentRunning ? .ambientActive : .ambientIdle }
        if agentRunning { return .agentWorking }     // post-commit, an agent is working
        if cursorAtEdge { return .edgeHoverReveal }  // idle reveal
        return .hidden
    }

    /// Whether the system cursor (Cocoa global coords) is within `threshold` of the chosen edge.
    nonisolated static func isAtEdge(
        cursor: CGPoint, screen: CGRect, edge: ScreenEdge, threshold: CGFloat = 4
    ) -> Bool {
        guard screen.minY...screen.maxY ~= cursor.y else { return false }
        switch edge {
        case .trailing: return cursor.x >= screen.maxX - threshold
        case .leading: return cursor.x <= screen.minX + threshold
        }
    }
}
