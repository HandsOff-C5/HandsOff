//
//  StateColors.swift
//  DirectorSidecar
//
//  State → color mapping. These switch over real contract enums (ExecutionStatus,
//  RiskLevel, ReadinessLevel), never raw strings (design.md / track-S § State binding), so a
//  contract change is a compile error, not a silent mis-color. `.spoken` values back the
//  VoiceOver labels (color is never the only signal — brand pillar 3).
//

import SwiftUI

/// Menu-bar / HUD readiness — derived Swift-side from the capability probes.
enum ReadinessLevel: Sendable {
    case ready
    case attention
    case blocked

    var spoken: String {
        switch self {
        case .ready: return "ready"
        case .attention: return "needs attention"
        case .blocked: return "blocked"
        }
    }
}

/// Risk of a resolved intent — @handsoff/contracts `risk_level`. Drives the risk tag color
/// and local approval policy; the shell does not trust model-provided `requires_approval`.
enum RiskLevel: String, Codable, Sendable, CaseIterable {
    case readOnly = "read_only"
    case reversible
    case mutating
    case destructiveExternal = "destructive_external"

    var spoken: String {
        switch self {
        case .readOnly: return "read only"
        case .reversible: return "reversible"
        case .mutating: return "mutating"
        case .destructiveExternal: return "destructive external"
        }
    }
}

extension Theme {
    /// Session/run status → StatusPill + row-dot color.
    func color(for status: ExecutionStatus) -> Color {
        switch status {
        case .running: return accent
        case .succeeded: return success
        case .failed, .rejected: return danger
        case .blocked: return warning
        case .queued: return textSecondary
        }
    }

    /// Readiness level → menu-bar / HUD readiness dot color.
    func color(for level: ReadinessLevel) -> Color {
        switch level {
        case .ready: return success
        case .attention: return warning
        case .blocked: return danger
        }
    }

    /// Risk level → risk tag color.
    func color(for risk: RiskLevel) -> Color {
        switch risk {
        case .readOnly: return textSecondary
        case .reversible: return info
        case .mutating: return warning
        case .destructiveExternal: return danger
        }
    }
}

extension ExecutionStatus {
    /// VoiceOver value for a session/run status pill.
    var spoken: String {
        switch self {
        case .queued: return "queued"
        case .running: return "running"
        case .succeeded: return "complete"
        case .failed: return "failed"
        case .blocked: return "needs greenlight"
        case .rejected: return "rejected"
        }
    }
}
