//
//  Cua.swift
//  DirectorSidecar
//
//  Port of the @handsoff/contracts cua.ts types the audit + intent contracts embed:
//  `cuaElementSchema`, `cuaWindowStateSchema`, `cuaActionRequestSchema`, `cuaActionResultSchema`.
//
//  Scope note: the CUA *adapter* surface (permission report, app/window listing, screenshots,
//  driver tool definitions) is the NEXT porting step (PORTING.md § Porting Order 2) and is not
//  ported here — only the result/state shapes the audit trail and the loop observation record.
//

import Foundation

extension Contracts {
    /// An AX element's frame in window-local screenshot-pixel space (top-left origin) — the SAME
    /// space the driver `click` tool's `x,y` (CGEvent) path consumes. Carried so the loop can fall
    /// back to a real coordinate click when an `element_index` AX action no-ops (#158: Catalyst
    /// sidebar rows ignore `AXPress`), and so the LLM can reason about on-screen layout.
    struct CuaElementFrame: Codable, Sendable, Equatable {
        let x: Double
        let y: Double
        let width: Double
        let height: Double

        /// The frame center — the point a synthetic CGEvent click targets.
        var centerX: Double { x + width / 2 }
        var centerY: Double { y + height / 2 }
    }

    /// `cuaElementSchema`: one AX element in a window-state snapshot. `frame`/`parentIndex`/`depth`/
    /// `token` are the per-element fields the driver returns that the audit/intent layer historically
    /// dropped — `frame` for the coordinate-click fallback, `parentIndex`/`depth` for tree structure,
    /// `token` for the driver's stable per-snapshot handle (preferred over `index` for dispatch).
    struct CuaElement: Codable, Sendable, Equatable {
        let id: String
        let index: Int?
        let role: String?
        let label: String?
        let value: String?
        let frame: CuaElementFrame?
        let parentIndex: Int?
        let depth: Int?
        let token: String?

        init(id: String, index: Int?, role: String?, label: String?, value: String?,
             frame: CuaElementFrame? = nil, parentIndex: Int? = nil, depth: Int? = nil,
             token: String? = nil) {
            self.id = id
            self.index = index
            self.role = role
            self.label = label
            self.value = value
            self.frame = frame
            self.parentIndex = parentIndex
            self.depth = depth
            self.token = token
        }
    }

    /// `cuaWindowStateSchema`. `elementCount`/`elements` default to 0/[] when absent.
    /// (The live Rust mapper reports `elementCount` but may leave `elements` empty — see
    /// ADR 0005 immediate blockers; any risk gating on semantic elements must verify this.)
    struct CuaWindowState: Decodable, Sendable, Equatable {
        let surface: SurfaceSnapshot
        let capturedAt: String
        let elementCount: Int
        let elements: [CuaElement]

        private enum Key: String, CodingKey {
            case surface, capturedAt, elementCount, elements
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Key.self)
            surface = try c.decode(SurfaceSnapshot.self, forKey: .surface)
            capturedAt = try c.decode(String.self, forKey: .capturedAt)
            elementCount = try c.decodeIfPresent(Int.self, forKey: .elementCount) ?? 0
            elements = try c.decodeIfPresent([CuaElement].self, forKey: .elements) ?? []
        }
    }

    /// `cuaActionRequestSchema`: the typed six-kind request the legacy ActionPlan executor
    /// issues (distinct from the generic `tool_call` passthrough). Discriminated on `kind`.
    enum CuaActionRequest: Decodable, Sendable, Equatable {
        case launchApp(appName: String, bundleId: String?)
        case getWindowState(target: ActionTarget)
        case click(target: ActionTarget)
        case typeText(target: ActionTarget, text: String)
        case setValue(target: ActionTarget, value: String)
        case screenshot(target: ActionTarget)

        private enum Key: String, CodingKey {
            case kind, appName, bundleId, target, text, value
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Key.self)
            switch try c.decode(String.self, forKey: .kind) {
            case "launch_app":
                self = .launchApp(appName: try c.decode(String.self, forKey: .appName),
                                  bundleId: try c.decodeIfPresent(String.self, forKey: .bundleId))
            case "get_window_state":
                self = .getWindowState(target: try c.decode(ActionTarget.self, forKey: .target))
            case "click":
                self = .click(target: try c.decode(ActionTarget.self, forKey: .target))
            case "type_text":
                self = .typeText(target: try c.decode(ActionTarget.self, forKey: .target),
                                 text: try c.decode(String.self, forKey: .text))
            case "set_value":
                self = .setValue(target: try c.decode(ActionTarget.self, forKey: .target),
                                 value: try c.decode(String.self, forKey: .value))
            case "screenshot":
                self = .screenshot(target: try c.decode(ActionTarget.self, forKey: .target))
            case let other:
                throw DecodingError.dataCorruptedError(
                    forKey: .kind, in: c,
                    debugDescription: "Unknown cua action request kind: \(other)")
            }
        }
    }

    /// `cuaActionResultSchema`: discriminated on `status`. Each variant carries an optional
    /// post-action window state.
    enum CuaActionResult: Decodable, Sendable, Equatable {
        case succeeded(summary: String, state: CuaWindowState?)
        case failed(error: String, state: CuaWindowState?)
        case blocked(reason: String, state: CuaWindowState?)

        private enum Key: String, CodingKey {
            case status, summary, error, reason, state
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Key.self)
            let state = try c.decodeIfPresent(CuaWindowState.self, forKey: .state)
            switch try c.decode(String.self, forKey: .status) {
            case "succeeded":
                self = .succeeded(summary: try c.decode(String.self, forKey: .summary), state: state)
            case "failed":
                self = .failed(error: try c.decode(String.self, forKey: .error), state: state)
            case "blocked":
                self = .blocked(reason: try c.decode(String.self, forKey: .reason), state: state)
            case let other:
                throw DecodingError.dataCorruptedError(
                    forKey: .status, in: c,
                    debugDescription: "Unknown cua action result status: \(other)")
            }
        }
    }
}
