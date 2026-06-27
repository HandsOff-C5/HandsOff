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
        if case let .succeeded(value) = await load() { return value }
        return []
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

/// The loop's "head" (`args.resolveIntent`): given the live input + the tool catalog, emit the next
/// driver tool call toward the goal (a `ready` tool_call intent), or signal done/clarify/blocked.
/// Risk is re-derived by the loop against the live snapshot — the resolver is never trusted for it.
typealias NextToolCallResolving = @Sendable (
    _ input: Contracts.IntentInput,
    _ createdAt: String,
    _ tools: [DriverToolDefinition]
) async -> Contracts.ResolvedIntent

enum LoopResolver {
    /// The production resolver: forward to the Worker-backed `NextToolCallResolver` (Track C) with
    /// a long-lived client. Keeps Worker config out of the loop — the app wiring supplies the client.
    static func worker(
        client: NextToolCallClient,
        model: String = NextToolCallResolver.defaultModel,
        replay: (any AgentReplayRecording)? = nil
    ) -> NextToolCallResolving {
        { input, createdAt, tools in
            await NextToolCallResolver.resolveNextToolCall(
                input, client: client, tools: tools, model: model, createdAt: createdAt, replay: replay)
        }
    }
}
