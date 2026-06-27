//
//  NativeActionRequest.swift
//  DirectorSidecar
//
//  #148 — the pure decode of a generic driver `call(tool:input:)` into the fields the in-process
//  native AX backend needs. No AX / CGEvent here, so the decode is unit-tested headlessly (the live
//  actuation that consumes it is on-device manual, like the camera path).
//
//  Today actuation goes ONLY through the external `cua-driver`, whose per-call spawn relies on a
//  separate `com.trycua.driver` TCC identity that is not granted — so its AX reads/clicks fail in
//  the bundled app. The fix is to attempt the mutating verbs IN-PROCESS using the Director's OWN
//  Accessibility grant; this type is the boundary that turns the driver's flat snake_case args into
//  a typed request the native backend can resolve to a real element.
//

import Foundation
import CoreGraphics

/// The mutating driver verbs the native AX backend can attempt in-process (#148). Any other tool
/// (reads, perception, launch) is not a native-actuation candidate and the hybrid router passes the
/// call straight through to the driver.
enum NativeActionKind: Equatable, Sendable {
    case click
    case rightClick
    case doubleClick
    case typeText
    case setValue

    /// Whether this verb injects synthetic mouse input (so its element resolves to a click POINT).
    var isClick: Bool {
        switch self {
        case .click, .rightClick, .doubleClick: return true
        case .typeText, .setValue: return false
        }
    }
}

/// A driver `call(tool:input:)` reduced to the fields the native AX backend needs. Pure value type.
/// Element resolution prefers an explicit `point` (args `x`/`y` → `AXUIElementCopyElementAtPosition`,
/// the point→element fix), then `elementIndex`, which indexes the SAME in-process AX enumeration the
/// hybrid driver's `get_window_state` emits — so the index the resolver picked maps back to a real
/// element. With neither present the request is not natively resolvable and the router falls back to
/// the driver (the (0,0) stub the rebuild source carried is deliberately NOT ported).
struct NativeActionRequest: Equatable, Sendable {
    let kind: NativeActionKind
    let pid: Int?
    let windowId: Int?
    let elementIndex: Int?
    let point: CGPoint?
    let text: String?
    let value: String?

    /// Decode a generic driver call into a native request, or nil when `tool` is not a native
    /// actuation verb (the hybrid router then passes the call straight through to the driver).
    static func decode(tool: String, input: JSONValue) -> NativeActionRequest? {
        guard let kind = kind(for: tool) else { return nil }
        let args = input.objectFields ?? [:]
        return NativeActionRequest(
            kind: kind,
            pid: args["pid"]?.intValue,
            windowId: args["window_id"]?.intValue,
            elementIndex: args["element_index"]?.intValue,
            point: Self.point(from: args),
            text: args["text"]?.stringValue,
            value: args["value"]?.stringValue)
    }

    /// Map a driver tool wire name to a native verb; nil for everything outside the mutating set.
    private static func kind(for tool: String) -> NativeActionKind? {
        switch tool {
        case "click": return .click
        case "right_click": return .rightClick
        case "double_click": return .doubleClick
        case "type_text": return .typeText
        case "set_value": return .setValue
        default: return nil
        }
    }

    /// A CG-global click point from explicit `x`/`y` args (both required). Absent → nil, and the
    /// backend resolves by `elementIndex` instead.
    private static func point(from args: [String: JSONValue]) -> CGPoint? {
        guard let x = args["x"]?.doubleValue, let y = args["y"]?.doubleValue else { return nil }
        return CGPoint(x: x, y: y)
    }
}

// Minimal typed accessors over the adapter's arbitrary-JSON value — scoped to this file so the
// driver-passthrough `JSONValue` keeps its single public decode/encode surface.
private extension JSONValue {
    var objectFields: [String: JSONValue]? {
        if case let .object(fields) = self { return fields }
        return nil
    }
    var doubleValue: Double? {
        if case let .number(value) = self { return value }
        return nil
    }
    var intValue: Int? {
        // Fail closed: the wire value is a Double, so only convert when it is finite, has no
        // fractional part (an `Int(3.7)` truncation would silently mis-index an element), and sits
        // within Int's representable range (`Int(1e300)` traps). Anything else → nil (no native id).
        guard let value = doubleValue,
              value.isFinite,
              value == value.rounded(.towardZero),
              value >= Double(Int.min),
              value < Double(Int.max) else { return nil }
        return Int(value)
    }
    var stringValue: String? {
        if case let .string(value) = self { return value }
        return nil
    }
}
