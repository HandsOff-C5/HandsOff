//
//  ContractJSONValue.swift
//  DirectorSidecar
//
//  A faithful arbitrary-JSON value, used where a contract field is a free record the
//  driver owns the per-key schema for: `ActionStep.tool_call.args` (z.record(z.unknown()))
//  is a self-describing passthrough — HandsOff does not re-model each tool's arg shape.
//  Codable so a tool_call round-trips its raw flat args (the driver's snake_case shape)
//  without lossy re-typing.
//

import Foundation

extension Contracts {
    /// One JSON value of any shape. `.null` decodes a literal `null`.
    indirect enum JSONValue: Codable, Sendable, Equatable {
        case null
        case bool(Bool)
        case number(Double)
        case string(String)
        case array([JSONValue])
        case object([String: JSONValue])

        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if c.decodeNil() {
                self = .null
            } else if let b = try? c.decode(Bool.self) {
                self = .bool(b)
            } else if let n = try? c.decode(Double.self) {
                self = .number(n)
            } else if let s = try? c.decode(String.self) {
                self = .string(s)
            } else if let a = try? c.decode([JSONValue].self) {
                self = .array(a)
            } else if let o = try? c.decode([String: JSONValue].self) {
                self = .object(o)
            } else {
                throw DecodingError.dataCorruptedError(
                    in: c, debugDescription: "Unrecognized JSON value")
            }
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            switch self {
            case .null: try c.encodeNil()
            case .bool(let b): try c.encode(b)
            case .number(let n): try c.encode(n)
            case .string(let s): try c.encode(s)
            case .array(let a): try c.encode(a)
            case .object(let o): try c.encode(o)
            }
        }
    }
}
