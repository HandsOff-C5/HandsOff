//
//  CuaDriverService.swift
//  DirectorSidecar
//
//  Swift `Process` adapter around the external `cua-driver` binary — the native replacement for
//  src-tauri/src/commands/cua.rs (Rust) + packages/cua/src/tauri-driver.ts (the Tauri invoke
//  client). Per ADR 0005, the driver stays external for the first native release; only the adapter
//  is ported. This service owns the read/perception/catalog/generic surface:
//
//    checkPermissions · listApps · listWindows · getWindowState · screenshot · listTools · call
//
//  The typed mutating wrappers (click/type_text/set_value/launch_app) are reachable through the
//  generic `call(tool:input:)` and are owned by the action-dispatch port (ADR 0005 step 3 /
//  Contracts.CuaActionRequest), so they are deliberately not duplicated here.
//
//  All driver I/O is off the actor's executor (Process is blocking); the parse/map/wrap logic is
//  the Process-free `CuaWire` core (CuaDriverWire.swift), so behavior is fixture-testable.
//

import Foundation

/// Resolves the `cua-driver` executable. Matches the Rust adapter, which relied on PATH lookup
/// (`Command::new("cua-driver")`); an absolute override exists for a bundled/pinned binary.
enum CuaExecutable: Sendable, Equatable {
    /// Resolve `name` from PATH at spawn time via `/usr/bin/env` (the Rust default behavior).
    case resolvedFromPath(String)
    /// A fully-qualified path to the binary.
    case absolute(String)

    static let `default` = CuaExecutable.resolvedFromPath("cua-driver")
}

actor CuaDriverService {
    private let executable: CuaExecutable

    init(executable: CuaExecutable = .default) {
        self.executable = executable
    }

    // MARK: Public surface — @handsoff/contracts CuaDriver (packages/cua/src/driver.ts)

    /// `cua-driver permissions status --json` → granted/denied report. Any failure (driver absent,
    /// bad JSON) degrades to unknown/unavailable rather than throwing — the Rust adapter's policy.
    func checkPermissions() async -> CuaResult<CuaPermissionReport> {
        do {
            return .succeeded(try CuaWire.decodePermissions(try await runRaw(["permissions", "status", "--json"])))
        } catch {
            return .succeeded(CuaWire.permissionsUnavailable)
        }
    }

    func listApps() async -> CuaResult<[CuaApp]> {
        await read { try CuaWire.decodeApps(try await self.callTool("list_apps", .object([:]))) }
    }

    func listWindows() async -> CuaResult<[CuaWindow]> {
        await read { try await self.windows() }
    }

    /// Focused-window AX state. Resolves the surface from the live window list (the Rust adapter
    /// re-lists to attach the surface), then reports the driver's element count.
    func getWindowState(pid: Int, windowId: Int) async -> CuaResult<CuaWindowState> {
        await read {
            let raw = try await self.callTool("get_window_state", Self.windowTarget(pid: pid, windowId: windowId, captureMode: "ax"))
            let surface = try await self.surface(pid: pid, windowId: windowId)
            return try CuaWire.decodeWindowState(raw: raw, surface: surface, capturedAt: Self.timestamp())
        }
    }

    /// Visual capture via the driver's `vision` window-state mode (inline base64 PNG).
    func screenshot(pid: Int, windowId: Int) async -> CuaResult<CuaScreenshot> {
        await read {
            let raw = try await self.callTool("get_window_state", Self.windowTarget(pid: pid, windowId: windowId, captureMode: "vision"))
            let surface = try await self.surface(pid: pid, windowId: windowId)
            return try CuaWire.decodeScreenshot(raw: raw, surface: surface, capturedAt: Self.timestamp())
        }
    }

    /// The driver's self-described tool catalog: `list-tools` for names+descriptions, then
    /// `describe <tool>` per tool for its `input_schema`. This is the agent's function set.
    func listTools() async -> CuaResult<[DriverToolDefinition]> {
        await read {
            let listing = String(decoding: try await self.runRaw(["list-tools"]), as: UTF8.self)
            var catalog: [DriverToolDefinition] = []
            for (name, description) in CuaWire.parseToolList(listing) {
                catalog.append(try await self.toolDefinition(name: name, description: description))
            }
            return catalog
        }
    }

    /// Generic passthrough to any driver tool — the full surface the agentic loop dispatches over.
    /// Valid JSON passes through; a prose confirmation line returns as a `.string(...)` value.
    func call(tool: String, input: JSONValue) async -> CuaResult<JSONValue> {
        await read {
            CuaWire.decodeCallValue(try await self.runRaw(["call", tool, try input.encodedString()]))
        }
    }

    // MARK: Internal composition

    private func windows() async throws -> [CuaWindow] {
        try CuaWire.decodeWindows(try await callTool("list_windows", .object(["on_screen_only": .bool(true)])))
    }

    /// Find the surface for a pid+window in the live list; the window can vanish between calls.
    private func surface(pid: Int, windowId: Int) async throws -> CuaWindow {
        guard let surface = try await windows().first(where: { $0.pid == pid && $0.windowId == windowId }) else {
            throw CuaDriverError.windowDisappeared
        }
        return surface
    }

    private func toolDefinition(name: String, description: String) async throws -> DriverToolDefinition {
        let describe = (try? await runRaw(["describe", name])).map { String(decoding: $0, as: UTF8.self) }
        let inputSchema = describe.flatMap(CuaWire.parseDescribeSchema)
        return DriverToolDefinition(name: name, description: description, inputSchema: inputSchema)
    }

    private func callTool(_ tool: String, _ input: JSONValue) async throws -> Data {
        try await runRaw(["call", tool, try input.encodedString()])
    }

    private static func windowTarget(pid: Int, windowId: Int, captureMode: String) -> JSONValue {
        .object([
            "pid": .number(Double(pid)),
            "window_id": .number(Double(windowId)),
            "capture_mode": .string(captureMode),
        ])
    }

    /// Run a producer and convert its thrown errors into the matching `CuaResult` arm, so the loop
    /// always sees a typed result instead of a Swift error (mirrors tauri-driver.ts's try/catch).
    private func read<Value: Sendable>(_ produce: () async throws -> Value) async -> CuaResult<Value> {
        do {
            return .succeeded(try await produce())
        } catch {
            return .failed(error: Self.describe(error))
        }
    }

    private static func describe(_ error: Error) -> String {
        switch error {
        case CuaDriverError.failedToStart(let message): return "cua-driver failed to start: \(message)"
        case CuaDriverError.nonZeroExit(let stderr): return "cua-driver failed: \(stderr)"
        case CuaDriverError.invalidJSON(let message): return "cua-driver returned invalid JSON: \(message)"
        case CuaDriverError.missingField(let field): return "CUA response missing \(field)"
        case CuaDriverError.windowDisappeared: return "CUA window disappeared before capture"
        default: return String(describing: error)
        }
    }

    private static func timestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }

    // MARK: Process boundary

    /// Spawn `cua-driver` with `args` and return raw stdout once it exits 0. A non-zero exit
    /// (unknown tool, malformed arg) becomes `CuaDriverError.nonZeroExit(stderr)`; a spawn failure
    /// becomes `.failedToStart`. Faithful to the Rust `run_cua_raw`/`ensure_success` pair.
    private func runRaw(_ args: [String]) async throws -> Data {
        let (launchPath, arguments) = resolvedCommand(args)
        return try await withCheckedThrowingContinuation { continuation in
            Self.processQueue.async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: launchPath)
                process.arguments = arguments
                let outPipe = Pipe()
                let errPipe = Pipe()
                process.standardOutput = outPipe
                process.standardError = errPipe

                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: CuaDriverError.failedToStart(error.localizedDescription))
                    return
                }

                // Drain stdout AND stderr concurrently before waiting: a screenshot's base64 PNG can
                // exceed the pipe buffer, and reading after waitUntilExit() would deadlock the child.
                let errLock = DispatchSemaphore(value: 0)
                var errData = Data()
                DispatchQueue.global(qos: .utility).async {
                    errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                    errLock.signal()
                }
                let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                errLock.wait()
                process.waitUntilExit()

                guard process.terminationStatus == 0 else {
                    continuation.resume(throwing: CuaDriverError.nonZeroExit(String(decoding: errData, as: UTF8.self)))
                    return
                }
                continuation.resume(returning: outData)
            }
        }
    }

    /// Resolve the executable + argv. PATH resolution mirrors the Rust default by delegating to
    /// `/usr/bin/env`, which searches PATH for the binary.
    private func resolvedCommand(_ args: [String]) -> (launchPath: String, arguments: [String]) {
        switch executable {
        case .absolute(let path):
            return (path, args)
        case .resolvedFromPath(let name):
            return ("/usr/bin/env", [name] + args)
        }
    }

    private static let processQueue = DispatchQueue(label: "com.handsoff.cua-driver", qos: .userInitiated)
}
