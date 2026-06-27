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

    /// The typed `blocked` result for a click target that no-op'd through BOTH addressing paths —
    /// the AX action AND a coordinate (CGEvent) click at the element's frame center both reported
    /// success while the window never changed (#158: a Catalyst sidebar row that ignores
    /// programmatic clicks). A clear no-progress stop, mirroring the KD2 failed-action floor.
    static func stalledClickBlock(_ step: Contracts.ActionStep) -> Contracts.CuaActionResult {
        .blocked(
            reason: "Stopped: \(StepDispatch.toolNameForStep(step)) on the same element kept " +
                "reporting success but the window never changed — the AX action and a coordinate " +
                "click both no-op'd after \(ClickEscalation.maxNoProgressRepeats) tries (the target " +
                "likely ignores programmatic clicks).",
            state: nil)
    }

    /// Whether the focused window's CONTENT changed between two observed states. nil/unknown states
    /// count as CHANGED (we can't prove a no-op), so the no-progress floor only fires on a definite,
    /// repeated no-change. Compares the semantic fingerprint (surface identity + element roles/labels/
    /// values + count), NOT per-tick geometry/timestamps, so incidental jitter doesn't mask a no-op.
    static func windowChanged(
        from before: Contracts.CuaWindowState?,
        to after: Contracts.CuaWindowState?
    ) -> Bool {
        guard let before, let after else { return true }
        return before.progressFingerprint != after.progressFingerprint
    }
}

/// Which addressing path a click was dispatched over — the AX action (`element_index`/`element_token`)
/// or the driver's coordinate (CGEvent) path (`x`/`y` at the element's frame center).
enum ClickMode: Equatable, Sendable {
    case ax
    case coordinate
}

/// The click executed last tick, carried so the next observation can judge whether it made progress.
/// `key` is the `StepDispatch.clickTargetKey` shared by a target's AX and coordinate variants.
struct ExecutedClick: Equatable, Sendable {
    let key: String
    let mode: ClickMode
}

/// Per-click-target escalation memory for #158. An `element_index`/`element_token` click that the
/// driver ACCEPTS (→ succeeded) but that leaves the window unchanged is a no-op — a Catalyst sidebar
/// row ignoring `AXPress`. On the first such no-op the loop escalates that target to the driver's
/// coordinate (CGEvent) path (a real mouse click at the element's frame center); if even that makes
/// no progress, the per-target count climbs until the floor (`maxNoProgressRepeats`) blocks the
/// target. Keyed by `clickTargetKey` so a target's AX and coordinate variants share state. Immutable,
/// threaded through the goal run exactly like `FailedActionMemory`.
struct ClickEscalation: Equatable, Sendable {
    /// Block a click target after this many consecutive no-progress dispatches (AX + coordinate).
    static let maxNoProgressRepeats = 3

    /// Targets whose next dispatch should use the coordinate path (their AX action already no-op'd).
    let coordinateTargets: Set<String>
    /// Per-target consecutive no-progress dispatch count (AX and coordinate combined).
    let noProgressCounts: [String: Int]

    init(coordinateTargets: Set<String> = [], noProgressCounts: [String: Int] = [:]) {
        self.coordinateTargets = coordinateTargets
        self.noProgressCounts = noProgressCounts
    }

    /// Whether the next dispatch of `key` should use the coordinate (CGEvent) path.
    func usesCoordinate(_ key: String) -> Bool { coordinateTargets.contains(key) }

    /// Whether `key` has stalled enough (both paths no-op'd) to block.
    func isExhausted(_ key: String) -> Bool {
        (noProgressCounts[key] ?? 0) >= Self.maxNoProgressRepeats
    }

    /// Record one no-progress dispatch of `key` made over `mode`: count it toward the floor and, if it
    /// was the AX path, escalate the target to the coordinate path for next time.
    func recordingNoProgress(_ key: String, mode: ClickMode) -> ClickEscalation {
        var counts = noProgressCounts
        counts[key, default: 0] += 1
        var coords = coordinateTargets
        if mode == .ax { coords.insert(key) }
        return ClickEscalation(coordinateTargets: coords, noProgressCounts: counts)
    }

    /// The click made progress — clear all escalation state for `key`.
    func clearing(_ key: String) -> ClickEscalation {
        guard coordinateTargets.contains(key) || noProgressCounts[key] != nil else { return self }
        var coords = coordinateTargets
        coords.remove(key)
        var counts = noProgressCounts
        counts[key] = nil
        return ClickEscalation(coordinateTargets: coords, noProgressCounts: counts)
    }

    /// The first step in `steps` whose click target is exhausted (block the whole tick), or nil.
    func firstExhausted(in steps: [Contracts.ActionStep]) -> Contracts.ActionStep? {
        steps.first { step in
            guard let key = StepDispatch.clickTargetKey(step) else { return false }
            return isExhausted(key)
        }
    }
}

extension Contracts.CuaWindowState {
    /// A stable fingerprint of the window's CONTENT — surface identity + the element list's
    /// role/label/value/index + the count — EXCLUDING the per-tick `capturedAt` and per-element
    /// geometry. Two ticks with the same fingerprint mean a click between them changed nothing: the
    /// #158 no-op signal. Deliberately ignores `frame` so a blinking cursor / 1px reflow doesn't mask
    /// a genuine no-op (a real navigation changes the element roles/labels, which this captures).
    var progressFingerprint: String {
        let surfaceKey = "\(surface.pid ?? -1):\(surface.windowId ?? -1):\(surface.title)"
        let elementsKey = elements
            .map { "\($0.index ?? -1)|\($0.role ?? "")|\($0.label ?? "")|\($0.value ?? "")" }
            .joined(separator: ";")
        return "\(surfaceKey)#n=\(elementCount)#\(elementsKey)"
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
