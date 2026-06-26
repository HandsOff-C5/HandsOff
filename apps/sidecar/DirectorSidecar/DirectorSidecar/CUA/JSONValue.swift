//
//  JSONValue.swift
//  DirectorSidecar
//
//  The CUA adapter's arbitrary-JSON value: `DriverToolDefinition.inputSchema`
//  (@handsoff/contracts cua.ts `z.unknown().nullable()`) and the generic `call(tool, input)`
//  argument + result (the driver's raw JSON, or its confirmation line wrapped as a string).
//
//  Top-level by design — distinct from the namespaced `Contracts.JSONValue`
//  (Contracts/ContractJSONValue.swift), which models `tool_call.args` for the audit/intent
//  closure. The two are intentionally separate (see PORTING.md notes 2–4): the adapter owns the
//  driver passthrough, the contracts port owns the audit record. Faithful to the Rust adapter's
//  use of `serde_json::Value` in src-tauri/src/commands/cua.rs — arbitrary JSON passes through
//  unchanged, and a plain-text driver confirmation degrades to `.string(...)`.
//

import Foundation

/// An arbitrary JSON value. Mirrors `serde_json::Value` / TypeScript `unknown` so the adapter
/// can carry driver-defined tool schemas and generic call payloads without a bespoke type per tool.
enum JSONValue: Codable, Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported JSON value"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case let .bool(value): try container.encode(value)
        case let .number(value): try container.encode(value)
        case let .string(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case let .object(value): try container.encode(value)
        }
    }
}

extension JSONValue {
    /// Decode a JSON value from raw driver bytes. `Bool` must be tried before `Double` (above)
    /// because `JSONDecoder` will otherwise read `true`/`false` as `1`/`0`.
    static func decode(_ data: Data) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: data)
    }

    /// Serialize to a compact JSON string for the driver CLI (`cua-driver call <tool> <json>`),
    /// matching how the Rust adapter passes `input.to_string()`.
    func encodedString() throws -> String {
        String(decoding: try JSONEncoder().encode(self), as: UTF8.self)
    }
}
