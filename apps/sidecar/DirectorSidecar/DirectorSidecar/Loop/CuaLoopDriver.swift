//
//  CuaLoopDriver.swift
//  DirectorSidecar
//
//  The injection seams the autonomous loop (Track A) depends on, so the observe→resolve→dispatch
//  loop is unit-testable with fakes (a real camera/mic/driver can't run under headless xcodebuild)
//  and so the pointing-fusion + Worker-client tracks attach behind a protocol rather than being
//  re-owned here. Three seams, mirroring the TS controller's injected args:
//
//    • CuaLoopDriver  — the read/perception/catalog/generic-call surface the loop drives. The real
//      `CuaDriverService` already has this exact shape (it conforms below); a fake driver returns
//      scripted results in tests. This is the `args.driver: CuaDriver` seam.
//    • IntentIntake   — turns a final transcript into the initial `IntentInput`. The DEFAULT is
//      speech-only (no pointing): the loop then grounds itself on the live window observation it
//      makes every tick, which is exactly the controller's no-gesture/no-head fallback path. The
//      pointing-fusion port (buildPointingEvidence.ts, a separate track) replaces this stub.
//    • NextToolCallResolving — the loop's "head": emits the next driver tool call toward the goal.
//      Defaults to the Worker resolver (Track C, NextToolCallResolver); tests inject a fake. This
//      is `args.resolveIntent`.
//

import Foundation

// MARK: - Driver seam

/// The CUA surface the loop drives — a subset of the full adapter surface (the loop never lists
/// apps / screenshots / checks permissions). `CuaDriverService` satisfies it verbatim.
protocol CuaLoopDriver: Sendable {
    func listWindows() async -> CuaResult<[CuaWindow]>
    func getWindowState(pid: Int, windowId: Int) async -> CuaResult<CuaWindowState>
    /// A vision capture of a window — used by the #158 coordinate-click fallback to recover the
    /// window's bounds (global points) + the screenshot's pixel size, the two factors that convert an
    /// element's global-point frame into the window-local screenshot pixels the `click` tool expects.
    func screenshot(pid: Int, windowId: Int) async -> CuaResult<CuaScreenshot>
    func listTools() async -> CuaResult<[DriverToolDefinition]>
    func call(tool: String, input: JSONValue) async -> CuaResult<JSONValue>
}

extension CuaDriverService: CuaLoopDriver {}

/// `createToolCatalog(driver).load()` (tool-catalog.ts): the driver's self-described tool surface,
/// loaded once and cached. A FAILED load is NOT cached, so a transient driver error retries on the
/// next tick. Held by the loop for the controller's life, like the TS `useRef(createToolCatalog(...))`.
@MainActor
final class ToolCatalog {
    private let driver: any CuaLoopDriver
    private var cached: [DriverToolDefinition]?

    /// Tools the driver self-describes but which always FAIL on this platform — never offer them to
    /// the resolver, or the loop wastes ticks dispatching a guaranteed-error call and never concludes
    /// the goal. `bring_to_front` is Windows-only: on macOS the driver returns a hard error
    /// ("bring_to_front is Windows-only … input tools do not need explicit foreground activation"),
    /// which the resolver kept choosing after a successful `launch_app`, looping the "open X" goal to
    /// dedup/budget instead of letting it finish satisfied. The macOS no-foreground contract means
    /// activation is never needed, so dropping the tool is behavior-preserving.
    static let unsupportedTools: Set<String> = ["bring_to_front"]

    /// Locally-handled tools (U3) appended to the driver's self-described surface so the resolver
    /// can choose them. `write_note` is the compose-and-write DESTINATION (the loop runs it
    /// natively via NoteWriter — `~/Documents/<title>.md` + open — never forwarding to the driver),
    /// so it is offered even when the driver tool load fails. JSON-schema params: `title`, `text`.
    static let localTools: [DriverToolDefinition] = [
        DriverToolDefinition(
            name: Contracts.DriverTool.writeNote.rawValue,
            description: "Write generated content to a new note — the DESTINATION for a compose-and-write task "
                + "(summarize / draft / rewrite / explain-in-writing): generate the deliverable yourself, then "
                + "write that generated text here. Creates ~/Documents/<title>.md and opens it. NEVER type the "
                + "user's request verbatim and NEVER hunt for a button named after the verb.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "title": .object([
                        "type": .string("string"),
                        "description": .string(
                            "Short note title; becomes the .md filename (sanitized, confined to ~/Documents)."),
                    ]),
                    "text": .object([
                        "type": .string("string"),
                        "description": .string("The full generated content to write into the note."),
                    ]),
                ]),
                "required": .array([.string("title"), .string("text")]),
            ])),
    ]

    init(driver: any CuaLoopDriver) { self.driver = driver }

    func load() async -> CuaResult<[DriverToolDefinition]> {
        if let cached { return .succeeded(cached) }
        let result = await driver.listTools()
        if case let .succeeded(value) = result {
            let supported = value.filter { !Self.unsupportedTools.contains($0.name) }
            cached = supported
            return .succeeded(supported)
        }
        return result
    }

    /// The tools the resolver is handed this tick — the loaded catalog, or `[]` on a failed load
    /// (the controller's `toolsResult.status === "succeeded" ? toolsResult.value : []`).
    func loadedTools() async -> [DriverToolDefinition] {
        let driverTools: [DriverToolDefinition]
        if case let .succeeded(value) = await load() { driverTools = value } else { driverTools = [] }
        return driverTools + Self.localTools
    }
}

// MARK: - Intent intake seam

/// Turns a final transcript into the initial `IntentInput` the goal loop starts from. The pointing
/// signals (gesture lock, gaze, head, capture trace, pointable windows) fuse here in the full port;
/// the loop core only needs the seam.
protocol IntentIntake: Sendable {
    func makeInput(for finalTranscript: Contracts.FinalTranscript, sessionId: String) async -> Contracts.IntentInput
}

/// The default intake: speech only, no pointing evidence or candidate surfaces. The loop then
/// grounds every tick on its live `get_window_state` observation, which is the controller's
/// behavior when no gesture/head/bound evidence exists. Swapped for the pointing-fusion intake
/// (buildPointingEvidence) when that track lands.
struct SpeechOnlyIntake: IntentIntake {
    func makeInput(for finalTranscript: Contracts.FinalTranscript, sessionId: String) async -> Contracts.IntentInput {
        Contracts.IntentInput(
            sessionId: sessionId,
            finalTranscript: finalTranscript,
            pointingEvidence: [],
            surfaceCandidates: [],
            goalSession: nil)
    }
}

// MARK: - Resolver seam

/// The loop's "head" (`args.resolveIntent`): given the live input + the tool catalog + an optional
/// window screenshot, emit the next driver tool call toward the goal (a `ready` tool_call intent), or
/// signal done/clarify/blocked. Risk is re-derived by the loop against the live snapshot — the
/// resolver is never trusted for it. `screenshot` is the optional vision turn (U5): the loop passes
/// the capture it already has (or nil); a closure that can't supply one ignores the 4th argument.
typealias NextToolCallResolving = @Sendable (
    _ input: Contracts.IntentInput,
    _ createdAt: String,
    _ tools: [DriverToolDefinition],
    _ screenshot: CuaScreenshot?
) async -> Contracts.ResolvedIntent

enum LoopResolver {
    /// The production resolver: forward to the Worker-backed `NextToolCallResolver` (Track C) with
    /// a long-lived client. Keeps Worker config out of the loop — the app wiring supplies the client.
    static func worker(client: NextToolCallClient, model: String = NextToolCallResolver.defaultModel) -> NextToolCallResolving {
        { input, createdAt, tools, screenshot in
            await NextToolCallResolver.resolveNextToolCall(
                input, client: client, tools: tools, model: model, createdAt: createdAt, screenshot: screenshot)
        }
    }
}
