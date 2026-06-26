//
//  PlanRunResult.swift
//  DirectorSidecar
//
//  Port of @handsoff/actions plan-run-result.ts + the @handsoff/cua `cuaResultToActionResult`
//  mapper, plus the one bridge the loop's dispatch needs between the TWO JSONValue families
//  (PORTING.md notes 4/6). Kept with the loop (Track A) because the loop is their only consumer
//  today; consolidate into the CUA layer if a second caller appears.
//
//  `PlanRunResult` is the terminal result of running one tick's action plan — the execution
//  status plus the optional typed driver result that produced it. The controller surfaces it as
//  its `runResult` state; the plan-preview panel renders it.
//

import Foundation

/// `PlanRunResult` (@handsoff/actions): `{ status: ExecutionStatus, result?: CuaActionResult }`.
struct PlanRunResult: Equatable, Sendable {
    let status: ExecutionStatus
    let result: Contracts.CuaActionResult?

    init(status: ExecutionStatus, result: Contracts.CuaActionResult? = nil) {
        self.status = status
        self.result = result
    }

    /// The controller's `{ status, result: actionResult }` where the status is derived from the
    /// driver result: a succeeded call is `.succeeded`, otherwise the result's own failed/blocked
    /// status carries through. Mirrors `actionResult.status === "succeeded" ? "succeeded" : actionResult.status`.
    static func fromActionResult(_ result: Contracts.CuaActionResult) -> PlanRunResult {
        PlanRunResult(status: result.executionStatus, result: result)
    }
}

extension Contracts.CuaActionResult {
    /// The `ExecutionStatus` this driver result maps to (succeeded/failed/blocked).
    var executionStatus: ExecutionStatus {
        switch self {
        case .succeeded: return .succeeded
        case .failed: return .failed
        case .blocked: return .blocked
        }
    }
}

/// `cuaResultToActionResult` (@handsoff/cua driver.ts): normalize a generic driver read result
/// (`CuaResult<JSONValue>` — the passthrough envelope) into a typed `Contracts.CuaActionResult`.
/// A failed/blocked envelope carries its error/reason; a success becomes a `succeeded` action
/// result with the fallback summary. The optional state-capture closure the TS exposes is unused
/// by the loop's dispatch (it passes no extractor), so it is omitted here — state stays nil.
func cuaResultToActionResult(_ result: CuaResult<JSONValue>, summary: String) -> Contracts.CuaActionResult {
    switch result {
    case .failed(let error):
        return .failed(error: error, state: nil)
    case .blocked(let reason):
        return .blocked(reason: reason, state: nil)
    case .succeeded:
        return .succeeded(summary: summary, state: nil)
    }
}

extension Contracts.JSONValue {
    /// Bridge the contract `tool_call.args` value family onto the adapter's driver-passthrough
    /// `JSONValue` (PORTING.md notes 4/6: the two are intentionally separate types of the same
    /// shape — the contracts port owns the audit record, the adapter owns the driver call). The
    /// loop's dispatch flattens a step's `[String: Contracts.JSONValue]` args into a single
    /// driver-side `.object(...)` to hand to `driver.call(tool:input:)`.
    var asDriverValue: JSONValue {
        switch self {
        case .null: return .null
        case .bool(let value): return .bool(value)
        case .number(let value): return .number(value)
        case .string(let value): return .string(value)
        case .array(let values): return .array(values.map(\.asDriverValue))
        case .object(let fields): return .object(fields.mapValues(\.asDriverValue))
        }
    }
}
