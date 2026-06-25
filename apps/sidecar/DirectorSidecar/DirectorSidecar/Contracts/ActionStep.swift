//
//  ActionStep.swift
//  DirectorSidecar
//
//  Port of @handsoff/contracts action-plan.ts `actionStepSchema` — the discriminated union
//  (on `kind`) of one step in an action plan, plus its `actionTargetSchema`. Faithful to all
//  seven variants including the generic `tool_call` (U3b) that reaches the full driver surface
//  by tool name. Distinct from the decode-only `ActionStepLite` (Bridge/LoopTypes.swift),
//  which flattens every kind to id/label/kind/targetTitle/proposed for the Inspector.
//

import Foundation

extension Contracts {
    /// `actionTargetSchema`: the surface a step addresses, with an optional AX element id /
    /// index into that surface's element list.
    struct ActionTarget: Codable, Sendable, Equatable {
        let surface: SurfaceSnapshot
        let elementId: String?
        let elementIndex: Int?
    }

    /// `actionStepSchema`. The legacy six kinds remain for the rule resolver; `tool_call`
    /// is the generic full-surface passthrough. `id`/`label` are shared by every variant.
    enum ActionStep: Decodable, Sendable, Equatable {
        case inspectWindowState(id: String, label: String, target: ActionTarget)
        case clickElement(id: String, label: String, target: ActionTarget)
        case typeText(id: String, label: String, target: ActionTarget, text: String)
        case setValue(id: String, label: String, target: ActionTarget, value: String)
        case captureScreenshot(id: String, label: String, target: ActionTarget)
        case launchApp(id: String, label: String, appName: String, bundleId: String?)
        case toolCall(id: String, label: String, tool: DriverTool, args: [String: JSONValue])

        /// The shared id, regardless of kind.
        var id: String {
            switch self {
            case let .inspectWindowState(id, _, _), let .clickElement(id, _, _),
                 let .captureScreenshot(id, _, _):
                return id
            case let .typeText(id, _, _, _), let .setValue(id, _, _, _):
                return id
            case let .launchApp(id, _, _, _): return id
            case let .toolCall(id, _, _, _): return id
            }
        }

        /// The shared human label, regardless of kind.
        var label: String {
            switch self {
            case let .inspectWindowState(_, label, _), let .clickElement(_, label, _),
                 let .captureScreenshot(_, label, _):
                return label
            case let .typeText(_, label, _, _), let .setValue(_, label, _, _):
                return label
            case let .launchApp(_, label, _, _): return label
            case let .toolCall(_, label, _, _): return label
            }
        }

        private enum Key: String, CodingKey {
            case kind, id, label, target, text, value, appName, bundleId, tool, args
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Key.self)
            let kind = try c.decode(String.self, forKey: .kind)
            let id = try c.decode(String.self, forKey: .id)
            let label = try c.decode(String.self, forKey: .label)

            switch kind {
            case "inspect_window_state":
                self = .inspectWindowState(id: id, label: label,
                                           target: try c.decode(ActionTarget.self, forKey: .target))
            case "click_element":
                self = .clickElement(id: id, label: label,
                                     target: try c.decode(ActionTarget.self, forKey: .target))
            case "type_text":
                self = .typeText(id: id, label: label,
                                 target: try c.decode(ActionTarget.self, forKey: .target),
                                 text: try c.decode(String.self, forKey: .text))
            case "set_value":
                self = .setValue(id: id, label: label,
                                 target: try c.decode(ActionTarget.self, forKey: .target),
                                 value: try c.decode(String.self, forKey: .value))
            case "capture_screenshot":
                self = .captureScreenshot(id: id, label: label,
                                          target: try c.decode(ActionTarget.self, forKey: .target))
            case "launch_app":
                self = .launchApp(id: id, label: label,
                                  appName: try c.decode(String.self, forKey: .appName),
                                  bundleId: try c.decodeIfPresent(String.self, forKey: .bundleId))
            case "tool_call":
                // `args` defaults to {} when absent (z.record(...).default({})).
                let args = try c.decodeIfPresent([String: JSONValue].self, forKey: .args) ?? [:]
                self = .toolCall(id: id, label: label,
                                 tool: try c.decode(DriverTool.self, forKey: .tool),
                                 args: args)
            default:
                throw DecodingError.dataCorruptedError(
                    forKey: .kind, in: c,
                    debugDescription: "Unknown action step kind: \(kind)")
            }
        }
    }
}
