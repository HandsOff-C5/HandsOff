//
//  CuaDriverWire.swift
//  DirectorSidecar
//
//  Driver-facing decode structs + the pure mapping/parsing core of the CUA adapter — a faithful
//  Swift port of the `map_*`, `parse_*`, and `*_field` functions in
//  src-tauri/src/commands/cua.rs. These are Process-free and fixture-testable: CuaDriverService
//  spawns `cua-driver`, hands the raw stdout here, and gets the adapter's top-level Cua* output back.
//
//  `cua-driver` speaks snake_case; the contract output is camelCase (CuaContracts.swift). The
//  driver decoder below uses `.convertFromSnakeCase` so the wire structs read the driver shape
//  directly without per-field CodingKeys.
//

import Foundation

/// Typed adapter failures. Mirrors the `Err(String)` arms of the Rust adapter, but keyed so the
/// service can map each to the right `CuaResult` arm and tests can assert cause.
enum CuaDriverError: Error, Equatable {
    case failedToStart(String)         // cua-driver could not be spawned
    case nonZeroExit(String)           // unknown tool / malformed arg — driver stderr
    case invalidJSON(String)           // driver stdout was not the expected JSON
    case missingField(String)          // a required field (e.g. a screenshot dimension) was absent
    case windowDisappeared             // target window vanished between the call and surface lookup
}

// MARK: - Driver wire structs (snake_case via convertFromSnakeCase)

struct DriverPermissionReport: Decodable {
    let accessibility: Bool
    let screenRecording: Bool
}

struct DriverApp: Decodable {
    let active: Bool
    let bundleId: String?
    let name: String
    let pid: Int
    let running: Bool
}

struct DriverAppList: Decodable {
    let apps: [DriverApp]
}

/// Window geometry from the driver. Tolerant: a window the driver can't measure decodes to no
/// `DriverBounds` (Rust `#[serde(default)]`) rather than failing the whole list.
struct DriverBounds: Decodable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}

struct DriverWindow: Decodable {
    let appName: String
    let title: String
    let pid: Int
    let windowId: Int
    let isOnScreen: Bool
    let zIndex: Int
    let bounds: DriverBounds?
}

struct DriverWindowList: Decodable {
    let windows: [DriverWindow]
}

struct DriverElement: Decodable {
    let elementIndex: Int?
    let elementToken: String?
    let role: String?
    let label: String?
    let value: JSONValue?
}

/// The fields the adapter reads out of a `get_window_state` response (ax mode → `elements`;
/// vision mode → the `screenshot_*` block). All optional; the mappers decide what's required.
struct DriverWindowStateRaw: Decodable {
    let elementCount: Int?
    let elements: [DriverElement]?
    let screenshotMimeType: String?
    let screenshotWidth: Int?
    let screenshotHeight: Int?
    let screenshotPngB64: String?
}

// MARK: - Mapping & parsing core

/// Process-free mapping + parsing. Every function mirrors a named function in `cua.rs` so the two
/// adapters stay behaviorally identical; the unit tests are a port of the Rust `#[cfg(test)]` block.
enum CuaWire {
    /// A `JSONDecoder` configured for the driver's snake_case wire shape.
    static func driverDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }

    // MARK: Permissions

    static func map(permissions report: DriverPermissionReport) -> CuaPermissionReport {
        CuaPermissionReport(
            accessibility: report.accessibility ? .granted : .denied,
            screenRecording: report.screenRecording ? .granted : .denied,
            driver: .running
        )
    }

    /// The report the Rust adapter returns when `cua-driver` is unreachable or its output won't parse.
    static let permissionsUnavailable = CuaPermissionReport(
        accessibility: .unknown,
        screenRecording: .unknown,
        driver: .unavailable
    )

    static func decodePermissions(_ data: Data) throws -> CuaPermissionReport {
        map(permissions: try driverDecoder().decode(DriverPermissionReport.self, from: data))
    }

    // MARK: Apps

    static func map(app: DriverApp) -> CuaApp {
        CuaApp(
            id: app.bundleId ?? app.name.lowercased(),
            name: app.name,
            pid: app.pid > 0 ? app.pid : nil,
            bundleId: app.bundleId,
            running: app.running,
            active: app.active
        )
    }

    static func decodeApps(_ data: Data) throws -> [CuaApp] {
        try driverDecoder().decode(DriverAppList.self, from: data).apps.map(map(app:))
    }

    // MARK: Windows

    static func map(window: DriverWindow, focused: Bool) -> CuaWindow {
        CuaWindow(
            id: "\(window.pid):\(window.windowId)",
            title: window.title.isEmpty ? window.appName : window.title,
            app: window.appName,
            pid: window.pid,
            windowId: window.windowId,
            availability: window.isOnScreen ? .available : .unknown,
            accessStatus: .accessible,
            focused: focused,
            bounds: window.bounds.map {
                CuaWindowBounds(x: $0.x, y: $0.y, width: $0.width, height: $0.height)
            },
            zIndex: window.zIndex
        )
    }

    /// Decode the window list and mark the single frontmost (max `zIndex`) window focused — the
    /// binder resolves a head/hand point to the frontmost window under it.
    static func decodeWindows(_ data: Data) throws -> [CuaWindow] {
        let list = try driverDecoder().decode(DriverWindowList.self, from: data)
        let frontmost = list.windows.map(\.zIndex).max()
        return list.windows.map { map(window: $0, focused: $0.zIndex == frontmost) }
    }

    // MARK: Window state & screenshot

    /// Driver AX elements, plus `element_count` when present. Older driver responses may only include
    /// the count, so elements still default to [].
    static func decodeWindowState(
        raw data: Data,
        surface: CuaWindow,
        capturedAt: String
    ) throws -> CuaWindowState {
        let raw = try driverDecoder().decode(DriverWindowStateRaw.self, from: data)
        let elements = (raw.elements ?? []).enumerated().map { offset, element in
            map(element: element, fallbackIndex: offset)
        }
        return CuaWindowState(
            surface: surface,
            capturedAt: capturedAt,
            elementCount: raw.elementCount ?? elements.count,
            elements: elements
        )
    }

    private static func map(element: DriverElement, fallbackIndex: Int) -> CuaElement {
        let id = element.elementToken?.nilIfEmpty
            ?? element.elementIndex.map { "element-\($0)" }
            ?? "element-\(fallbackIndex)"
        return CuaElement(
            id: id,
            index: element.elementIndex,
            role: element.role,
            label: element.label,
            value: element.value?.stringForElementValue
        )
    }

    static func decodeScreenshot(
        raw data: Data,
        surface: CuaWindow,
        capturedAt: String
    ) throws -> CuaScreenshot {
        let raw = try driverDecoder().decode(DriverWindowStateRaw.self, from: data)
        guard let mimeType = raw.screenshotMimeType else { throw CuaDriverError.missingField("screenshot_mime_type") }
        guard let width = raw.screenshotWidth else { throw CuaDriverError.missingField("screenshot_width") }
        guard let height = raw.screenshotHeight else { throw CuaDriverError.missingField("screenshot_height") }
        guard let pngBase64 = raw.screenshotPngB64 else { throw CuaDriverError.missingField("screenshot_png_b64") }
        return CuaScreenshot(
            surface: surface,
            capturedAt: capturedAt,
            mimeType: mimeType,
            width: width,
            height: height,
            pngBase64: pngBase64
        )
    }

    // MARK: Tool catalog

    /// Parse one `name: description` line from `cua-driver list-tools`. Splits on the FIRST `": "`
    /// only, so a description that itself contains a colon survives intact.
    static func parseToolLine(_ line: String) -> (name: String, description: String)? {
        guard let separator = line.range(of: ": ") else { return nil }
        let name = line[..<separator.lowerBound].trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }
        let description = line[separator.upperBound...].trimmingCharacters(in: .whitespaces)
        return (name, description)
    }

    static func parseToolList(_ stdout: String) -> [(name: String, description: String)] {
        stdout.split(whereSeparator: \.isNewline).compactMap { parseToolLine(String($0)) }
    }

    /// Extract the `input_schema:` JSON block from `cua-driver describe <tool>` output (the block
    /// is everything from the first `{` after the marker to the end). Returns nil when absent.
    static func parseDescribeSchema(_ describeOutput: String) -> JSONValue? {
        guard let marker = describeOutput.range(of: "input_schema:") else { return nil }
        let afterMarker = describeOutput[marker.upperBound...]
        guard let braceStart = afterMarker.firstIndex(of: "{") else { return nil }
        let block = afterMarker[braceStart...].trimmingCharacters(in: .whitespacesAndNewlines)
        return try? JSONValue.decode(Data(block.utf8))
    }

    // MARK: Generic call

    /// The generic `call` result: valid JSON passes through unchanged; a plain-text driver
    /// confirmation degrades to `.string(...)` so the passthrough never fails on a tool that
    /// confirms in prose (Rust `run_cua_value`).
    static func decodeCallValue(_ data: Data) -> JSONValue {
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if let value = try? JSONValue.decode(Data(text.utf8)) {
            return value
        }
        return .string(text)
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

private extension JSONValue {
    var stringForElementValue: String? {
        switch self {
        case .null: return nil
        case .string(let value): return value
        case .bool(let value): return value ? "true" : "false"
        case .number(let value):
            if value.isFinite, value >= Double(Int.min), value <= Double(Int.max), value.rounded() == value {
                return String(Int(value))
            }
            return String(value)
        case .array, .object: return nil
        }
    }
}
