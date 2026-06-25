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
    /// The full HUD panel shows only once there is real loop content — ambient `.listening` is
    /// the micro-HUD's job (G3). This keeps the two overlays from both showing at once.
    var showsFullPanel: Bool { isVisible && phase != .listening }

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
        send(.stopListening)
        reset()
    }

    // MARK: Commit / Greenlight (G2b)

    /// Whether a non-destructive ready intent can commit-and-execute directly (fn-end).
    nonisolated static func canCommit(_ intent: ResolvedIntentLite?) -> Bool {
        intent?.status == .ready && intent?.riskLevel != .destructive
    }

    /// fn-end COMMIT: execute the resolved intent. Non-destructive only — a destructive intent
    /// must go through `greenlight()`. Sends `commit`; engine runs the plan; runResult flips us
    /// to .complete. (fn-end detection is engine-owned — confirm the hotkey wiring.)
    func commit() {
        guard Self.canCommit(intent) else { return }
        send(.commit)
        phase = .executing
    }

    /// Optional destructive approval: send greenlight, then execute.
    func greenlight(now: Date = Date()) {
        guard intent?.status == .ready, isDestructive, let actionId = intent?.id else { return }
        send(.greenlight(actionId: actionId, decidedAt: Self.iso(now)))
        phase = .executing
    }

    /// Reject the (destructive) plan and dismiss without executing.
    func reject(now: Date = Date()) {
        if let actionId = intent?.id {
            send(.reject(actionId: actionId, decidedAt: Self.iso(now)))
        }
        reset()
    }

    private func send(_ command: Command) {
        guard let connection else { return }
        Task { await connection.send(command) }
    }

    private nonisolated static func iso(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    // MARK: Frame reducer

    func apply(_ frame: BridgeFrame) {
        // The HUD only consumes loop content once activation has begun (setListening → .listening);
        // while hidden it ignores frames so the dashboard's data never pops the HUD open uninvited.
        switch frame {
        case let .transcript(event):
            guard phase != .hidden else { return }
            transcript = event
            if phase == .listening || phase == .transcribing { phase = .transcribing }
        case let .referents(payload):
            guard phase != .hidden else { return }
            referents = payload.surfaces
            selectedReferent = payload.selected
            if phase != .awaitingGreenlight, phase != .intentReady, phase != .executing {
                phase = .referentsResolved
            }
        case let .intent(intent):
            guard phase != .hidden else { return }
            self.intent = intent
            phase = Self.phase(for: intent)
            if intent.status != .ready { errorReason = intent.reason }
        case let .runResult(result):
            guard phase != .hidden else { return }
            runResult = result.status
            phase = Self.phase(forRunResult: result.status)
        case let .error(reason):
            errorReason = reason
            phase = .error
        case .state, .sessions, .cursor, .gaze, .unknown:
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
