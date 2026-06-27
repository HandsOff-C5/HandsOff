//
//  CuaContracts.swift
//  DirectorSidecar
//
//  The CUA *adapter surface* output types — the part of @handsoff/contracts cua.ts the audit/
//  intent port (Contracts/Cua.swift) deliberately left for the adapter step (its scope note: the
//  "permission report, app/window listing, screenshots, driver tool definitions … is the NEXT
//  porting step"). Covers `cuaPermissionReportSchema`, `cuaAppSchema`, `cuaWindowSchema`,
//  `cuaWindowStateSchema`, `cuaScreenshotSchema`, `driverToolDefinitionSchema`, and the read
//  envelope `CuaResult<T>`.
//
//  TOP-LEVEL BY DESIGN, distinct from the namespaced `Contracts.Cua*` (PORTING.md notes 3–4):
//  the adapter's `CuaWindowState`/`CuaScreenshot` carry the rich `CuaWindow` (a SurfaceSnapshot
//  superset with focus/bounds/zIndex — the live window the user acts on), whereas
//  `Contracts.CuaWindowState` carries a PLAIN `SurfaceSnapshot` for the audit/intent record.
//  Not interchangeable; a future consolidation candidate, not a bug. The shared surface-status
//  *enums* (`Contracts.SurfaceAvailability`/`SurfaceAccessStatus`) ARE reused — one vocabulary.
//
//  Field names are camelCase to match the JSON wire shape; the driver-facing snake_case decode
//  structs live in CuaDriverWire.swift. Drift-guarded by decode tests in DirectorSidecarTests.
//

import Foundation

// MARK: - Read-result envelope

/// Read-tool result — @handsoff/contracts `CuaResult<T>` (cua.ts). The loop branches on `status`;
/// a driver/parse failure surfaces as `.failed`, never a thrown error (mirrors tauri-driver.ts).
enum CuaResult<Value: Sendable>: Sendable {
    case succeeded(Value)
    case failed(error: String)
    case blocked(reason: String)
}

// MARK: - Permissions

/// macOS TCC permission state — @handsoff/contracts `permissionStateSchema` (readiness.ts).
/// `Cua`-prefixed so it does not collide with a future readiness-service enum.
enum CuaPermissionState: String, Codable, Sendable, Equatable {
    case granted
    case denied
    case notDetermined = "not-determined"
    case restricted
    case unknown
}

/// Driver liveness — @handsoff/contracts `z.enum(["running","unavailable","unknown"])` (cua.ts).
enum CuaDriverStatus: String, Codable, Sendable, Equatable {
    case running
    case unavailable
    case unknown
}

/// `cuaPermissionReportSchema`. The adapter maps the driver's `{accessibility, screen_recording}`
/// booleans to granted/denied and reports the driver as `running`; an unreachable driver degrades
/// the whole report to unknown/unavailable.
struct CuaPermissionReport: Codable, Sendable, Equatable {
    let accessibility: CuaPermissionState
    let screenRecording: CuaPermissionState
    let driver: CuaDriverStatus
}

// MARK: - Apps & windows

/// `cuaAppSchema`. `pid`/`bundleId` are optional (an installed-but-not-running app has no pid);
/// the adapter always emits `running`/`active`, so they stay non-optional to mirror the produced shape.
struct CuaApp: Codable, Sendable, Equatable, Identifiable {
    let id: String
    let name: String
    let pid: Int?
    let bundleId: String?
    let running: Bool
    let active: Bool
}

/// `cuaWindowBoundsSchema` — geometry in global virtual-desktop px (a secondary display's origin
/// may be negative). Omitted when the driver couldn't measure the window.
struct CuaWindowBounds: Codable, Sendable, Equatable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}

/// `cuaWindowSchema` — a `SurfaceSnapshot` extended with focus, geometry, and stacking order.
/// `zIndex`: HIGHER = frontmost (the adapter marks the max-zIndex on-screen window focused).
/// Reuses the strict `Contracts` surface-status enums so it is a literal SurfaceSnapshot superset.
struct CuaWindow: Codable, Sendable, Equatable, Identifiable {
    let id: String
    let title: String
    let app: String
    let pid: Int
    let windowId: Int
    let availability: Contracts.SurfaceAvailability
    let accessStatus: Contracts.SurfaceAccessStatus
    let focused: Bool
    let bounds: CuaWindowBounds?
    let zIndex: Int

    /// The lite `Contracts.SurfaceSnapshot` the audit/intent record embeds (CuaWindow is a superset).
    var surface: Contracts.SurfaceSnapshot {
        Contracts.SurfaceSnapshot(
            id: id, title: title, app: app, pid: pid, windowId: windowId,
            availability: availability, accessStatus: accessStatus
        )
    }
}

// MARK: - Window state & screenshot

/// One accessibility element — @handsoff/contracts `cuaElementSchema` (cua.ts). The adapter keeps a
/// top-level copy so `CuaWindowState` stays in the adapter's own surface family. `frame`/`parentIndex`/
/// `depth`/`token` are the per-element fields the driver returns (`get_window_state` structured
/// `elements`) — `frame` enables the coordinate-click fallback (#158), the rest enrich the LLM
/// snapshot. Reuses `Contracts.CuaElementFrame` so the adapter and audit families share one geometry.
struct CuaElement: Codable, Sendable, Equatable {
    let id: String
    let index: Int?
    let role: String?
    let label: String?
    let value: String?
    let frame: Contracts.CuaElementFrame?
    let parentIndex: Int?
    let depth: Int?
    let token: String?

    init(id: String, index: Int?, role: String?, label: String?, value: String?,
         frame: Contracts.CuaElementFrame? = nil, parentIndex: Int? = nil, depth: Int? = nil,
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

/// `cuaWindowStateSchema`. `capturedAt` is an ISO-8601 timestamp the adapter stamps at capture (the
/// Rust layer did not; tauri-driver.ts did). `surface` carries the full `CuaWindow` (rich), unlike
/// `Contracts.CuaWindowState` which carries a plain `SurfaceSnapshot` for the audit record.
struct CuaWindowState: Codable, Sendable, Equatable {
    let surface: CuaWindow
    let capturedAt: String
    let elementCount: Int
    let elements: [CuaElement]
}

/// `cuaScreenshotSchema`. The driver returns the capture inline as base64 PNG via the `vision`
/// window-state mode; the adapter validates each field loudly. `surface` is the rich `CuaWindow`.
struct CuaScreenshot: Codable, Sendable, Equatable {
    let surface: CuaWindow
    let capturedAt: String
    let mimeType: String
    let width: Int
    let height: Int
    let pngBase64: String
}

// MARK: - Tool catalog

/// `driverToolDefinitionSchema`. The driver self-describes its surface (`cua-driver list-tools`
/// + `describe <tool>`), so the agent's function set has zero HandsOff-side schema duplication.
/// `inputSchema` is nil when the driver emits no schema block. (Distinct from `Contracts.DriverTool`,
/// the static tool-NAME enum used for risk keying — this is the live, described catalog ENTRY.)
struct DriverToolDefinition: Codable, Sendable, Equatable {
    let name: String
    let description: String
    let inputSchema: JSONValue?
}
