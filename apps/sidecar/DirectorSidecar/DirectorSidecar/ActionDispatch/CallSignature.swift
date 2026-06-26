//
//  CallSignature.swift
//  DirectorSidecar
//
//  Port of the loop-dedup helpers extracted from
//  apps/desktop/src/features/voice-cua/useVoiceCuaController.ts (`callSignature` + the
//  `failedSignatures` recovery floor). Kept with the dispatch layer (Track B) because the
//  signature IS the (tool, args) `driverCallForStep` produces — they are pure, React-free
//  execution logic the loop (PORTING.md § Porting Order 3) composes with the live driver.
//
//  KD2 recovery floor: the resolver sometimes re-issues an identical FAILING call (e.g.
//  launch_app on an app that does not exist). The loop remembers a failed (tool, args)
//  signature and refuses to dispatch it again this goal, so a dead action can't run away to
//  the budget — while a genuine alternative the resolver tries still flows. Only verbatim
//  failures are remembered; successful calls are never recorded, so legitimate repeats (a
//  second scroll) keep working.
//

import Foundation

/// Caseless namespace for the pure dedup helpers.
enum ActionDedup {
    /// `callSignature`: a stable (tool, args) signature for loop-dedup. The actual driver call a
    /// step dispatches, with args' keys SORTED so the same logical call always hashes the same
    /// regardless of key order.
    static func callSignature(_ step: Contracts.ActionStep) -> String {
        let (tool, args) = StepDispatch.driverCallForStep(step)
        let body = args.keys.sorted()
            .map { key in "\(key)=\(args[key]!.signatureJSON)" }
            .joined(separator: "&")
        return "\(tool):\(body)"
    }

    /// The typed `blocked` result for a step whose (tool, args) already failed this goal — a
    /// clear stop instead of looping the dead action to the budget. Mirrors the controller's
    /// KD2 guard reason verbatim.
    static func repeatedCallBlock(_ step: Contracts.ActionStep) -> Contracts.CuaActionResult {
        .blocked(
            reason: "Stopped: the resolver kept retrying a call that already failed (\(StepDispatch.toolNameForStep(step))).",
            state: nil)
    }
}

/// The immutable (tool, args)-signature memory a goal run carries — the controller's
/// `failedSignatures` set, lifted out of React state into a pure value type. Recording a
/// failure and probing a plan for a repeat are the two operations the loop needs.
struct FailedActionMemory: Equatable, Sendable {
    let signatures: Set<String>

    init(_ signatures: Set<String> = []) {
        self.signatures = signatures
    }

    /// A copy that also remembers `signature`. A nil signature (the step succeeded) is a no-op,
    /// so successful calls are never recorded and legitimate repeats keep flowing.
    func recording(_ signature: String?) -> FailedActionMemory {
        guard let signature else { return self }
        return FailedActionMemory(signatures.union([signature]))
    }

    /// The first step in `steps` whose call signature already failed this goal, or nil. The loop
    /// blocks the whole tick on a hit (see `ActionDedup.repeatedCallBlock`).
    func firstRepeated(in steps: [Contracts.ActionStep]) -> Contracts.ActionStep? {
        steps.first { signatures.contains(ActionDedup.callSignature($0)) }
    }

    /// Whether `step`'s call signature already failed this goal.
    func contains(_ step: Contracts.ActionStep) -> Bool {
        signatures.contains(ActionDedup.callSignature(step))
    }
}

extension Contracts.JSONValue {
    /// A stable, deterministic JSON-ish rendering for the dedup signature — object keys sorted,
    /// integral numbers printed without a trailing `.0` (matching the driver's flat scalar args).
    /// NOT a general JSON serializer: it exists only so the same logical call hashes identically.
    var signatureJSON: String {
        switch self {
        case .null:
            return "null"
        case let .bool(value):
            return value ? "true" : "false"
        case let .number(value):
            if value.isFinite, value.rounded() == value, abs(value) < 1e15 {
                return String(Int(value))
            }
            return String(value)
        case let .string(value):
            return Self.quote(value)
        case let .array(values):
            return "[" + values.map(\.signatureJSON).joined(separator: ",") + "]"
        case let .object(values):
            let body = values.keys.sorted()
                .map { "\(Self.quote($0)):\(values[$0]!.signatureJSON)" }
                .joined(separator: ",")
            return "{" + body + "}"
        }
    }

    private static func quote(_ string: String) -> String {
        var out = "\""
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out += "\""
        return out
    }
}
