//
//  LoopEngine.swift
//  DirectorSidecar
//
//  ADR 0005 Track D — "bridge or no-bridge": the no-bridge, temporary path. The in-process engine
//  that makes the ported `VoiceCuaLoop` the app's engine of record. Before this, the loop core was
//  built nowhere and the UI streamed from the loopback socket (`BridgeConnection`) talking to a
//  hidden TypeScript engine. This object wires the Swift loop DIRECTLY:
//
//    • observe → the loop's @Observable state (intent / runResult / session) is projected onto the
//      `BridgeFrame` family the existing UI already consumes (LoopFrameMapping). No view-model
//      rewrite, no socket, no bridge topic expansion.
//    • command  → the UI's `Command`s are routed to the loop's own surface
//      (greenlight→approve, reject→reject, stop/pause→interrupt) instead of a socket write.
//    • speech   → live STT `.final` events START a goal (`handleFinalTranscript`); partial/final
//      events also surface as HUD `transcript` frames.
//
//  @MainActor because it owns `VoiceCuaLoop` (a @MainActor @Observable) and drives the @MainActor
//  view models through `onFrame`/`onState`. The loop's driver/resolver/intake are injected (the app
//  supplies the real CUA driver + Worker resolver; tests supply fakes), so the engine itself stays
//  transport-pure and unit-testable.
//

import Foundation
import Observation
import OSLog

@MainActor
final class LoopEngine: CommandSink {
    private let loop: VoiceCuaLoop
    private let readinessProbe: @Sendable () -> ReadinessPayload
    /// Optional async probe of the cua-driver DAEMON's own TCC report. When present, `refreshReadiness`
    /// emits a SECOND, merged readiness frame once it returns — so the accessibility/screen-recording/
    /// cua tiles reflect the daemon (the process a task actually runs through), not Director's own TCC.
    /// nil in tests (they assert the single synchronous base frame).
    private let cuaPermissionProbe: (@Sendable () async -> CuaPermissionReport?)?
    private let agentLabel: String

    /// Frame fan-out to the view models (set by the app). Called on the main actor.
    var onFrame: ((BridgeFrame) -> Void)?
    /// Connection-state fan-out (set by the app). An in-process engine is `.connected` once started.
    var onState: ((ConnectionState) -> Void)?

    // The loop exposes only the CURRENT session; the menu/dashboard render a fleet. Accumulate the
    // sessions we observe (insertion order) so the list grows across goals, titled by the goal text.
    private var sessionOrder: [String] = []
    private var sessions: [String: SupervisionSession] = [:]
    private var sessionTitles: [String: String] = [:]
    /// The transcript of the goal currently starting — applied as the next new session's title.
    private var pendingGoalText: String?

    private var started = false
    /// The in-flight goal run (fire-and-forget, like the TS controller). Held so a second push-to-talk
    /// turn supersedes the first; interrupting the loop is the explicit cancel (KD6), not Task cancel.
    private var goalTask: Task<Void, Never>?

    init(
        loop: VoiceCuaLoop,
        agentLabel: String = "Director",
        readinessProbe: @escaping @Sendable () -> ReadinessPayload = { ReadinessService.probe() },
        cuaPermissionProbe: (@Sendable () async -> CuaPermissionReport?)? = nil
    ) {
        self.loop = loop
        self.agentLabel = agentLabel
        self.readinessProbe = readinessProbe
        self.cuaPermissionProbe = cuaPermissionProbe
    }

    // MARK: Lifecycle

    /// Mark the in-process engine connected, publish the first readiness probe, and begin observing
    /// the loop. Idempotent.
    func start() {
        guard !started else { return }
        started = true
        DirectorDiagnostics.loop.info("engine started")
        onState?(.connected)
        refreshReadiness()
        observeLoop()
        emitCurrentState()
    }

    /// Re-probe macOS TCC and publish a fresh readiness frame. The app calls this when listening
    /// turns on (the moment a stale mic/speech grant would matter), so the menu/dashboard reflect a
    /// permission the user just changed without a relaunch.
    func refreshReadiness() {
        DirectorDiagnostics.loop.info("readiness probe requested")
        let base = readinessProbe()
        onFrame?(.state(topic: "readiness", readiness: base))
        // Then overlay the cua-driver daemon's own grants (accessibility/screen-recording/cua) — the
        // process a task runs through — so a missing CUA grant surfaces UP FRONT as a readiness blocker
        // instead of a restart-required prompt mid-task. A second frame; latest-wins for the UI.
        guard let cuaPermissionProbe else { return }
        Task { @MainActor in
            guard let report = await cuaPermissionProbe() else { return }
            let merged = ReadinessService.merging(base, cuaReport: report)
            DirectorDiagnostics.loop.info("cua readiness accessibility=\(report.accessibility.rawValue, privacy: .public) screen_recording=\(report.screenRecording.rawValue, privacy: .public) driver=\(report.driver.rawValue, privacy: .public)")
            onFrame?(.state(topic: "readiness", readiness: merged))
        }
    }

    // MARK: Speech intake

    /// Consume a live STT event. Partial/final both surface as HUD `transcript` frames; a `.final`
    /// additionally STARTS a goal — the push-to-talk trigger that makes the loop the engine of record.
    func ingestSpeech(_ event: SpeechService.Event) {
        switch event {
        case .ready:
            break
        case let .partial(text, confidence, latencyMs, receivedAt):
            DirectorDiagnostics.loop.debug("speech partial chars=\(text.count, privacy: .public) confidence=\(confidence, privacy: .public)")
            onFrame?(.transcript(LoopFrameMapping.transcript(
                partial: true, text: text, confidence: confidence, latencyMs: latencyMs, receivedAt: receivedAt)))
        case let .final(text, confidence, latencyMs, receivedAt):
            DirectorDiagnostics.loop.info("speech final chars=\(text.count, privacy: .public) confidence=\(confidence, privacy: .public)")
            onFrame?(.transcript(LoopFrameMapping.transcript(
                partial: false, text: text, confidence: confidence, latencyMs: latencyMs, receivedAt: receivedAt)))
            startGoal(Contracts.FinalTranscript(
                text: text, confidence: confidence, latencyMs: latencyMs, receivedAt: receivedAt))
        case let .error(error, _):
            DirectorDiagnostics.loop.error("speech error \(error.message, privacy: .public)")
            onFrame?(.error(reason: error.message))
        }
    }

    /// Drive the loop from a final transcript. Fire-and-forget (the loop's interrupt is the cancel
    /// path); the goal text titles the session the loop is about to create.
    private func startGoal(_ finalTranscript: Contracts.FinalTranscript) {
        pendingGoalText = finalTranscript.text
        DirectorDiagnostics.loop.info("goal task started chars=\(finalTranscript.text.count, privacy: .public)")
        goalTask = Task { [loop] in await loop.handleFinalTranscript(finalTranscript) }
    }

    // MARK: Commands (CommandSink)

    /// Route a UI command to the loop's own surface. `startListening` (mic up) is owned by the app's
    /// listening toggle; `commit` is subsumed by the autonomous loop (read/reversible ticks already
    /// auto-run, so there is nothing to commit); `openHome`/`selectSession` are UI-only.
    func send(_ command: Command) async {
        switch command {
        case .greenlight:
            await loop.approve()
        case .reject:
            await loop.reject()
        case .pauseAll, .pauseSession, .stopListening:
            // The always-available interrupt (KD6). Safe on fn-release: a new goal's
            // `handleFinalTranscript` resets the interrupt flag before it runs, so stopping the mic
            // never kills the goal that the just-spoken transcript is about to start.
            loop.interrupt()
        case .startListening, .commit, .openHome, .selectSession, .resumeSession:
            // resumeSession: per-agent pause/resume is client-side UI state today; there's no loop
            // counterpart to the interrupt yet (engine-side resume is deferred), so this is a no-op.
            break
        }
    }

    // MARK: Loop observation → frames

    /// Re-arming Observation tracking: `onChange` fires once (synchronously, pre-commit) on the first
    /// touched property, so we hop to the main actor to read the SETTLED state, emit, and re-arm. The
    /// loop mutates several properties per tick between awaits; reading the union after the batch is
    /// latest-wins — the same delivery guarantee the socket gave the UI.
    private func observeLoop() {
        withObservationTracking {
            _ = loop.intent
            _ = loop.runResult
            _ = loop.session
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.emitCurrentState()
                self.observeLoop()
            }
        }
    }

    private func emitCurrentState() {
        if let intent = LoopFrameMapping.lite(from: loop.intent) {
            onFrame?(.intent(intent))
        }
        if let session = loop.session {
            if sessions[session.id] == nil {
                sessionOrder.append(session.id)
                sessionTitles[session.id] = pendingGoalText
            }
            sessions[session.id] = LoopFrameMapping.wireSession(
                session, title: sessionTitles[session.id], agentLabel: agentLabel)
        }
        if !sessionOrder.isEmpty {
            onFrame?(.sessions(SessionsPayload(sessions: sessionOrder.compactMap { sessions[$0] }, counts: nil)))
        }
        if let runResult = loop.runResult, let sessionId = loop.session?.id {
            onFrame?(.runResult(RunResultPayload(status: runResult.status, sessionId: sessionId)))
        }
        // H4: project the per-call Intention Log onto the `audit` topic the log views render. The
        // loop keeps `auditEvents` scoped to the current session, so this is the live goal's log;
        // each tick re-projects the whole (append-only) list — latest-wins, like the other frames.
        if !loop.auditEvents.isEmpty {
            onFrame?(.audit(LoopFrameMapping.auditLog(loop.auditEvents)))
        }
    }
}
