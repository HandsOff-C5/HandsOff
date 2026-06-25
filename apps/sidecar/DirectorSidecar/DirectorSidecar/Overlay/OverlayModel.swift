//
//  OverlayModel.swift
//  DirectorSidecar
//
//  G5 cursor overlay state. Two roles in one click-through window:
//   - the Director cursor (kind:user) — hugs the system cursor while active, travels to the
//     pointing target on a kind:user frame, returns on stop, travels off on commit;
//   - agent cursors (kind:agent) — one per running agent (the AI-engineer Supervise fleet),
//     positioned from cursorPosition {kind:agent}.
//  Latest-wins per id; out-of-order (older ts) frames are dropped. Reducer is pure-ish + tested.
//

import Foundation
import CoreGraphics
import Observation

struct DirectorCursor: Identifiable, Equatable, Sendable {
    enum Kind: Sendable { case user, agent }
    enum State: String, Sendable { case hugging, moving, locked, idle, poof }

    let id: String
    let kind: Kind
    var label: String?
    /// Contract-space target (top-left, y-down). `nil` for the hugging Director cursor (which
    /// follows the local system cursor instead).
    var contractPoint: CGPoint?
    var state: State
    var confidence: Double
    var lastTs: Double
}

@MainActor
@Observable
final class OverlayModel {
    private(set) var cursors: [DirectorCursor] = []
    /// Live system-cursor position in Cocoa coords (from a global monitor) — the Director cursor
    /// hugs this while active and not pointing.
    private(set) var systemCursor: CGPoint = .zero

    @ObservationIgnored private var active = false

    var isVisible: Bool { !cursors.isEmpty }

    static let userId = "user"
    /// The Director cursor trails just below-right of the OS pointer (so it reads as *following*,
    /// not leading). View space is y-down, so a positive height pushes it downward.
    static let hugOffset = CGSize(width: 14, height: 14)

    // MARK: inputs

    /// Listening on → the Director (.user) cursor appears, hugging the system cursor. Off → remove it.
    func setActive(_ on: Bool) {
        active = on
        if on {
            if !cursors.contains(where: { $0.id == Self.userId }) {
                cursors.append(DirectorCursor(id: Self.userId, kind: .user, label: nil,
                                              contractPoint: nil, state: .hugging, confidence: 1, lastTs: 0))
            }
        } else {
            cursors.removeAll { $0.kind == .user }
        }
    }

    func setSystemCursor(_ point: CGPoint) {
        systemCursor = point
    }

    func apply(_ frame: BridgeFrame) {
        switch frame {
        case let .cursor(pointers):
            applyPointers(pointers)
        case let .runResult(result):
            poofAgent(result.sessionId)
        case .state, .sessions, .transcript, .referents, .intent, .gaze, .error, .unknown:
            break
        }
    }

    private func applyPointers(_ pointers: [Pointer]) {
        // Agent cursors mirror the latest frame's agent set; the .user cursor updates in place and
        // persists (hugging) when absent. Per-id stale frames are dropped.
        let agentPointers = pointers.filter { $0.kind == "agent" }
        let liveAgentIds = Set(agentPointers.map(\.id))

        for pointer in pointers {
            upsert(pointer)
        }
        // Remove agent cursors no longer present in the frame (an agent that stopped acting).
        cursors.removeAll { $0.kind == .agent && !liveAgentIds.contains($0.id) }
    }

    private func upsert(_ pointer: Pointer) {
        let id = pointer.id
        if let existing = cursors.first(where: { $0.id == id }), pointer.ts < existing.lastTs {
            return // stale / out-of-order — drop
        }
        let kind: DirectorCursor.Kind = pointer.kind == "agent" ? .agent : .user
        var state = Self.mapState(pointer.state)
        // A user pointer at rest (idle/hugging) means "stopped pointing" → hug the system cursor
        // (no contract target). Agents always carry a target.
        let userResting = kind == .user && (state == .idle || state == .hugging)
        if userResting { state = .hugging }
        let contractPoint: CGPoint? = userResting ? nil : CGPoint(x: pointer.x, y: pointer.y)

        let cursor = DirectorCursor(
            id: id, kind: kind, label: pointer.agentLabel,
            contractPoint: contractPoint, state: state,
            confidence: pointer.confidence ?? 1, lastTs: pointer.ts
        )
        if let index = cursors.firstIndex(where: { $0.id == id }) {
            cursors[index] = cursor
        } else {
            cursors.append(cursor)
        }
    }

    private func poofAgent(_ sessionId: String?) {
        guard let sessionId, let index = cursors.firstIndex(where: { $0.id == sessionId }) else { return }
        cursors[index].state = .poof
        cursors.removeAll { $0.id == sessionId } // remove after poof (view animates the dissolve)
    }

    func setConnection(_ state: ConnectionState) {
        if state == .engineDown { cursors.removeAll() } // never a stranded cursor
    }

    // MARK: pure helpers (unit-tested)

    /// Map a wire Pointer.state to a cursor state. `idle` for a user pointer == back to hugging.
    nonisolated static func mapState(_ raw: String) -> DirectorCursor.State {
        DirectorCursor.State(rawValue: raw) ?? .moving
    }

    /// Resolve a cursor's position in OVERLAY-VIEW coords (top-left origin, y-down — the overlay
    /// window covers the primary screen, so SwiftUI's space matches the contract space directly).
    /// A contract target maps straight through; the hugging Director cursor flips the Cocoa
    /// system-cursor (bottom-left) into view space and offsets it beside the OS pointer.
    nonisolated static func resolvedViewPoint(
        for cursor: DirectorCursor, systemCursorCocoa: CGPoint, primaryHeight: CGFloat
    ) -> CGPoint {
        if let contract = cursor.contractPoint {
            return CGPoint(x: contract.x, y: contract.y)
        }
        return CGPoint(
            x: systemCursorCocoa.x + hugOffset.width,
            y: primaryHeight - systemCursorCocoa.y + hugOffset.height
        )
    }
}
