//
//  CuaAdapterTests.swift
//  DirectorSidecarTests
//
//  Port of the Rust adapter's #[cfg(test)] block (src-tauri/src/commands/cua.rs) plus contract
//  decode/round-trip drift guards. Every case feeds real `cua-driver`-shaped JSON (snake_case) or
//  real CLI text through the Process-free `CuaWire` core — no mocks, no fabricated outputs. Output
//  is the canonical `Contracts.*` shape the supervision loop consumes.
//

import Testing
import Foundation
@testable import DirectorSidecar

/// The resolved rich window used as the surface for window-state/screenshot cases (the adapter's
/// `CuaWindowState`/`CuaScreenshot` carry the full `CuaWindow`, not a plain SurfaceSnapshot).
private let sampleSurface = CuaWindow(
    id: "42:7", title: "Notes", app: "Notes", pid: 42, windowId: 7,
    availability: .available, accessStatus: .accessible, focused: true,
    bounds: nil, zIndex: 10
)

// MARK: - Permissions

@Test func mapsPermissionBooleansToContractStates() throws {
    let report = try CuaWire.decodePermissions(Data(#"{"accessibility":true,"screen_recording":false}"#.utf8))
    #expect(report.accessibility == .granted)
    #expect(report.screenRecording == .denied)
    #expect(report.driver == .running)
}

@Test func permissionsDegradeToUnavailableReport() {
    // The Rust adapter returns this when cua-driver is unreachable or its output won't parse.
    let report = CuaWire.permissionsUnavailable
    #expect(report.accessibility == .unknown)
    #expect(report.screenRecording == .unknown)
    #expect(report.driver == .unavailable)
}

@Test func diagnosticCommandSummaryRedactsDriverJSONArgs() {
    let summary = DirectorDiagnostics.commandSummary(["call", "type_text", #"{"text":"lorem ipsum"}"#])
    #expect(summary == "call type_text <json 22 chars>")
    #expect(!summary.contains("lorem ipsum"))
}

// MARK: - Apps

@Test func mapsDriverAppsToContractApps() throws {
    let json = #"""
    {"apps":[
      {"active":true,"bundle_id":"com.apple.Notes","name":"Notes","pid":42,"running":true},
      {"active":false,"name":"Preview","pid":0,"running":false}
    ]}
    """#
    let apps = try CuaWire.decodeApps(Data(json.utf8))

    let running = apps[0]
    #expect(running.id == "com.apple.Notes")
    #expect(running.pid == 42)
    #expect(running.running)
    #expect(running.active)

    // No bundle id → id falls back to the lowercased name; pid 0 (not running) → nil.
    let installed = apps[1]
    #expect(installed.id == "preview")
    #expect(installed.pid == nil)
    #expect(installed.bundleId == nil)
    #expect(!installed.running)
}

// MARK: - Windows

@Test func mapsDriverWindowsAndMarksFrontmostFocused() throws {
    let json = #"""
    {"windows":[
      {"app_name":"Notes","title":"","pid":42,"window_id":7,"is_on_screen":true,"z_index":10,
       "bounds":{"x":100,"y":200,"width":300,"height":400}},
      {"app_name":"Safari","title":"Start Page","pid":50,"window_id":3,"is_on_screen":true,"z_index":20}
    ]}
    """#
    let windows = try CuaWire.decodeWindows(Data(json.utf8))

    let notes = windows[0]
    #expect(notes.id == "42:7")
    #expect(notes.title == "Notes")          // empty title falls back to the app name
    #expect(notes.app == "Notes")
    #expect(notes.availability == .available)
    #expect(notes.accessStatus == .accessible)
    #expect(notes.zIndex == 10)
    #expect(!notes.focused)                  // lower z-index → not frontmost
    #expect(notes.bounds?.x == 100)
    #expect(notes.bounds?.height == 400)

    let safari = windows[1]
    #expect(safari.focused)                  // max z-index → frontmost
    #expect(safari.bounds == nil)            // unmeasured window degrades to no geometry
}

@Test func dropsAutomationInfrastructureWindowsAndRefocusesRealFrontmost() throws {
    // The cua-driver daemon paints a full-screen "Cua Driver" window with the HIGHEST z-index; it
    // must be dropped so the observe loop reads the real frontmost app (Notes), not the driver's own
    // 0-element surface. "Director" (our own app) is dropped too.
    let json = #"""
    {"windows":[
      {"app_name":"Cua Driver","title":"","pid":999,"window_id":1,"is_on_screen":true,"z_index":99},
      {"app_name":"Director","title":"Director","pid":998,"window_id":2,"is_on_screen":true,"z_index":50},
      {"app_name":"Notes","title":"Note","pid":42,"window_id":7,"is_on_screen":true,"z_index":10},
      {"app_name":"Safari","title":"Start","pid":50,"window_id":3,"is_on_screen":true,"z_index":20}
    ]}
    """#
    let windows = try CuaWire.decodeWindows(Data(json.utf8))
    #expect(windows.count == 2)                              // Cua Driver + Director dropped
    #expect(windows.allSatisfy { $0.app != "Cua Driver" && $0.app != "Director" })
    let focused = windows.first { $0.focused }
    #expect(focused?.app == "Safari")                        // frontmost among the REAL windows
}

@Test func offscreenWindowReportsUnknownAvailability() throws {
    let json = #"{"windows":[{"app_name":"Mail","title":"Inbox","pid":9,"window_id":1,"is_on_screen":false,"z_index":5}]}"#
    let windows = try CuaWire.decodeWindows(Data(json.utf8))
    #expect(windows[0].availability == .unknown)
}

// MARK: - Window state & screenshot

@Test func mapsDriverWindowStateElements() throws {
    let json = #"""
    {"element_count":3,"elements":[
      {"element_index":0,"element_token":"s0001:0","role":"AXWindow","label":"Notes"},
      {"element_index":5,"role":"AXButton","label":"Send","value":true},
      {"role":"AXStaticText","value":{"ignored":"object"}}
    ]}
    """#
    let state = try CuaWire.decodeWindowState(raw: Data(json.utf8), surface: sampleSurface, capturedAt: "2026-06-25T00:00:00.000Z")
    #expect(state.elementCount == 3)
    #expect(state.elements.map(\.id) == ["s0001:0", "element-5", "element-2"])
    #expect(state.elements[0].index == 0)
    #expect(state.elements[1].role == "AXButton")
    #expect(state.elements[1].label == "Send")
    #expect(state.elements[1].value == "true")
    #expect(state.elements[2].value == nil)
    #expect(state.surface.id == sampleSurface.id)
    #expect(state.capturedAt == "2026-06-25T00:00:00.000Z")

    // Missing element_count falls back to the mapped element count.
    let countFromElements = try CuaWire.decodeWindowState(
        raw: Data(#"{"elements":[{"element_index":9,"role":"AXTextField"}]}"#.utf8),
        surface: sampleSurface,
        capturedAt: "t")
    #expect(countFromElements.elementCount == 1)
    #expect(countFromElements.elements[0].id == "element-9")

    let empty = try CuaWire.decodeWindowState(raw: Data("{}".utf8), surface: sampleSurface, capturedAt: "t")
    #expect(empty.elementCount == 0)
    #expect(empty.elements.isEmpty)
}

@Test func decodesScreenshotFieldsFromVisionState() throws {
    let json = #"""
    {"screenshot_mime_type":"image/png","screenshot_width":640,"screenshot_height":480,"screenshot_png_b64":"abc123"}
    """#
    let shot = try CuaWire.decodeScreenshot(raw: Data(json.utf8), surface: sampleSurface, capturedAt: "t")
    #expect(shot.mimeType == "image/png")
    #expect(shot.width == 640)
    #expect(shot.height == 480)
    #expect(shot.pngBase64 == "abc123")
}

@Test func screenshotValidatesMissingFieldLoudly() {
    #expect(throws: CuaDriverError.missingField("screenshot_png_b64")) {
        _ = try CuaWire.decodeScreenshot(
            raw: Data(#"{"screenshot_mime_type":"image/png","screenshot_width":1,"screenshot_height":1}"#.utf8),
            surface: sampleSurface,
            capturedAt: "t"
        )
    }
}

// MARK: - Tool catalog parsing

@Test func parsesListToolsLinesIntoNameAndDescription() {
    #expect(CuaWire.parseToolLine("scroll: Scroll the target pid's focused region")?.name == "scroll")
    #expect(CuaWire.parseToolLine("scroll: Scroll the target pid's focused region")?.description == "Scroll the target pid's focused region")

    // A description may itself contain a colon; only the first ": " splits.
    let listApps = CuaWire.parseToolLine("list_apps: List macOS apps: running and installed")
    #expect(listApps?.name == "list_apps")
    #expect(listApps?.description == "List macOS apps: running and installed")

    #expect(CuaWire.parseToolLine("") == nil)
    #expect(CuaWire.parseToolLine("no colon here") == nil)
}

@Test func parseToolListSkipsBlankAndMalformedLines() {
    let listing = "scroll: Scroll a region\n\nnope\nclick: Click an element\n"
    let tools = CuaWire.parseToolList(listing)
    #expect(tools.map(\.name) == ["scroll", "click"])
}

@Test func extractsInputSchemaBlockFromDescribeOutput() throws {
    let describe = "name: scroll\n\ndescription:\nScroll a region.\n\ninput_schema:\n{\n  \"type\": \"object\",\n  \"required\": [\"pid\", \"direction\"]\n}\n"
    let schema = try #require(CuaWire.parseDescribeSchema(describe))
    guard case let .object(fields) = schema else { Issue.record("expected object schema"); return }
    #expect(fields["type"] == .string("object"))
    #expect(fields["required"] == .array([.string("pid"), .string("direction")]))
}

@Test func describeWithoutSchemaBlockYieldsNil() {
    #expect(CuaWire.parseDescribeSchema("name: x\n\ndescription:\nNo schema here.\n") == nil)
}

// MARK: - Generic call passthrough

@Test func decodeCallValuePassesJsonThroughUnchanged() {
    let value = CuaWire.decodeCallValue(Data(#"{"ok":true,"count":2}"#.utf8))
    guard case let .object(fields) = value else { Issue.record("expected object"); return }
    #expect(fields["ok"] == .bool(true))
    #expect(fields["count"] == .number(2))
}

@Test func decodeCallValueWrapsConfirmationLineAsString() {
    // Action tools confirm in prose; the passthrough must not fail on non-JSON.
    let value = CuaWire.decodeCallValue(Data("Inserted text\n".utf8))
    #expect(value == .string("Inserted text"))
}

@Test func jsonValueRoundTripsThroughEncodedString() throws {
    let input = JSONValue.object(["pid": .number(42), "on_screen_only": .bool(true)])
    let encoded = try input.encodedString()
    #expect(try JSONValue.decode(Data(encoded.utf8)) == input)
}

// MARK: - Contract round-trip drift guard

@Test func windowStateRoundTripsAsCamelCaseContract() throws {
    let state = CuaWindowState(surface: sampleSurface, capturedAt: "2026-06-25T00:00:00.000Z", elementCount: 0, elements: [])
    let data = try JSONEncoder().encode(state)
    let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(json["capturedAt"] != nil)                       // camelCase on the wire
    let surface = try #require(json["surface"] as? [String: Any])
    #expect(surface["windowId"] != nil)
    #expect(surface["zIndex"] != nil)                        // rich CuaWindow surface, not plain SurfaceSnapshot
    #expect(surface["accessStatus"] as? String == "accessible")
    let decoded = try JSONDecoder().decode(CuaWindowState.self, from: data)
    #expect(decoded == state)
}
