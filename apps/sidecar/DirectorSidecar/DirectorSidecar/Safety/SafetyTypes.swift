//
//  SafetyTypes.swift
//  DirectorSidecar
//
//  Phase 4a safety primitives — localized value types.
//
//  These are the minimal value types the RiskGate and the hash-chained AuditLog need,
//  ported as SELF-CONTAINED `internal` types (no Envelope import — the Director is a
//  separate module). They mirror the source engine's `ActionArg` / `Taint` / `UndoToken`
//  (App/Sources/Envelope, App/Sources/RuleBook) so the ports read identically, but live
//  here so the Safety types compile without dragging the engine contracts in.
//
//  NOTE: the risk vocabulary is NOT redefined here — the Director's own `RiskLevel`
//  (Theme/StateColors.swift) is reused as the gate's tier vocabulary.

import Foundation

/// Provenance taint (engine ARCHITECTURE §5/§10): trusted vs attacker-influenceable.
/// A tainted arg forces the gate to require human approval regardless of the verb's tier.

/// One action argument; each arg carries its own taint (engine ARCHITECTURE §5).
struct ActionArg: Codable, Equatable, Sendable {
    var name: String
    var value: String
    var taint: Taint
    init(name: String, value: String, taint: Taint) {
        self.name = name
        self.value = value
        self.taint = taint
    }
}

/// The undo token returned for a committed action (engine FR-10) — every commit is undoable.
struct UndoToken: Codable, Equatable, Sendable {
    /// A unique-per-commit identifier (carries no PII).
    let id: String
    /// The action this token can undo.
    let action: String
    init(id: String, action: String) {
        self.id = id
        self.action = action
    }
}
