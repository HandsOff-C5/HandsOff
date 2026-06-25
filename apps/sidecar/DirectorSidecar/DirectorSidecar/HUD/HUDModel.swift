//
//  HUDModel.swift
//  DirectorSidecar
//
//  G2 Listening HUD state model. A BridgeFrame reducer derives the HUD phase from the loop
//  topics (transcript/referents/intent/runResult), latest-wins. G2a renders these read-only;
//  the commit-to-execute + optional destructive Greenlight footer wire up in G2b. The phase +
//  Greenlight-policy derivations are pure/nonisolated → unit-tested without a panel.
//

import Foundation
import Observation

enum HUDPhase: Equatable, Sendable {
    case hidden
    case listening           // header only (fn active, before transcript)
    case transcribing        // partial/final transcript streaming
    case referentsResolved   // ≥1 referent chip
    case intentReady         // intent resolved, non-destructive (auto-runs on commit, no footer)
    case awaitingGreenlight  // destructive intent — optional Greenlight footer shown
    case executing
    case complete
    case error
}

@MainActor
@Observable
final class HUDModel {
    private(set) var phase: HUDPhase = .hidden
    private(set) var transcript: TranscriptEvent?
    private(set) var referents: [SurfaceSnapshot] = []
    private(set) var selectedReferent: SelectedReferent?
    private(set) var intent: ResolvedIntentLite?
    private(set) var runResult: ExecutionStatus?
    private(set) var errorReason: String?

    /// The shared bridge connection (set by the app) — for the StopControl abort path.
    @ObservationIgnored var connection: BridgeConnection?

    var isVisible: Bool { phase != .hidden }

    // MARK: Greenlight-policy derivations (revised: destructive-only)

    var isDestructive: Bool { intent?.riskLevel == .destructive }
    /// Footer (Greenlight/Dismiss) shows ONLY for a ready destructive intent.
    var showFooter: Bool { Self.showFooter(for: intent) }
    /// Everything non-destructive auto-runs on commit (read_only/reversible/mutating).
    var autoRun: Bool { Self.autoRun(for: intent) }

    nonisolated static func showFooter(for intent: ResolvedIntentLite?) -> Bool {
        intent?.status == .ready && intent?.riskLevel == .destructive
    }

    nonisolated static func autoRun(for intent: ResolvedIntentLite?) -> Bool {
        intent?.status == .ready && intent?.riskLevel != .destructive
    }

    /// Pure phase for a resolved intent (destructive gates; everything else is ready-to-run).
    nonisolated static func phase(for intent: ResolvedIntentLite) -> HUDPhase {
        switch intent.status {
        case .ready:
            return intent.riskLevel == .destructive ? .awaitingGreenlight : .intentReady
        case .clarificationRequired, .blocked:
            return .error
        }
    }

    nonisolated static func phase(forRunResult status: ExecutionStatus) -> HUDPhase {
        switch status {
        case .succeeded: return .complete
        case .failed, .rejected: return .error
        case .blocked: return .awaitingGreenlight
        case .queued, .running: return .executing
        }
    }

    // MARK: Listening lifecycle (optimistic, Swift-local)

    /// Bring the HUD up on activation (before any transcript) or tear it down.
    func setListening(_ on: Bool) {
        if on {
            if phase == .hidden || phase == .complete { resetTransient() }
            phase = .listening
        } else {
            reset()
        }
    }

    /// StopControl = cancel/abort: stop the mic, do NOT execute, hide the HUD.
    func cancel() {
        if let connection { Task { await connection.send(.stopListening) } }
        reset()
    }

    // MARK: Frame reducer

    func apply(_ frame: BridgeFrame) {
        switch frame {
        case let .transcript(event):
            transcript = event
            if phase == .hidden || phase == .listening || phase == .transcribing {
                phase = .transcribing
            }
        case let .referents(payload):
            referents = payload.surfaces
            selectedReferent = payload.selected
            if phase != .awaitingGreenlight, phase != .intentReady, phase != .executing {
                phase = .referentsResolved
            }
        case let .intent(intent):
            self.intent = intent
            phase = Self.phase(for: intent)
            if intent.status != .ready { errorReason = intent.reason }
        case let .runResult(result):
            runResult = result.status
            phase = Self.phase(forRunResult: result.status)
        case let .error(reason):
            errorReason = reason
            phase = .error
        case .state, .sessions, .cursor, .unknown:
            break // not consumed by the HUD
        }
    }

    func setConnection(_ state: ConnectionState) {
        // The HUD freezes (dims) on disconnect but keeps last-known-good; reconnect re-primes.
        if state == .engineDown, isVisible { phase = .error; errorReason = "Reconnecting…" }
    }

    private func reset() {
        phase = .hidden
        resetTransient()
    }

    private func resetTransient() {
        transcript = nil
        referents = []
        selectedReferent = nil
        intent = nil
        runResult = nil
        errorReason = nil
    }
}
