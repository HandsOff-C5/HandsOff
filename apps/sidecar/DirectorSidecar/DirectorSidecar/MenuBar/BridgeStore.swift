//
//  BridgeStore.swift
//  DirectorSidecar
//
//  G1 (T-G1.6): the @Observable menu-bar view model. Owns the one shared BridgeConnection,
//  applies decoded frames to UI state on the main actor, and sends commands. The derivations
//  (readiness level, canListen, MenuSession mapping) are pure static functions so they are
//  unit-tested without a live socket.
//

import Foundation
import Observation

/// A menu row's session — the UI projection of a wire `SupervisionSession`.
struct MenuSession: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let agentLabel: String
    let status: ExecutionStatus
    let startedAt: Date

    init(_ session: SupervisionSession) {
        id = session.id
        title = session.title ?? "Session \(session.id)"
        agentLabel = session.agentLabel ?? "Agent"
        status = session.status
        startedAt = BridgeStore.parseISO(session.startedAt) ?? Date(timeIntervalSince1970: 0)
    }

    init(id: String, title: String, agentLabel: String, status: ExecutionStatus, startedAt: Date) {
        self.id = id
        self.title = title
        self.agentLabel = agentLabel
        self.status = status
        self.startedAt = startedAt
    }
}

@MainActor
@Observable
final class BridgeStore {
    private(set) var sessions: [MenuSession] = []
    private(set) var counts = SessionCounts(running: 0, needsGreenlight: 0, done: 0)
    private(set) var readiness: [CapabilityProbe] = []
    private(set) var menuReadiness: ReadinessLevel = .attention
    private(set) var readinessLabel: String = "Connecting"
    private(set) var connection: ConnectionState = .connecting
    private(set) var isListening = false
    private(set) var canListen = false

    /// Per-agent paused state — the single source of truth for the whole app (rail, menu, dashboard
    /// all read it). A paused agent stops "working" (its mark's halo/waveform), and every surface
    /// offers Resume instead of Pause. Optimistic + sent to the engine.
    private(set) var pausedSessionIds: Set<String> = []
    func isPaused(_ id: String) -> Bool { pausedSessionIds.contains(id) }
    func togglePaused(_ id: String) {
        let pause = !isPaused(id)
        if pause { pausedSessionIds.insert(id) } else { pausedSessionIds.remove(id) }
        send(pause ? .pauseSession(id) : .resumeSession(id))
    }

    var runningCount: Int { counts.running }
    var needsGreenlightCount: Int { counts.needsGreenlight }
    var doneCount: Int { counts.done }

    /// The command sink (set by the app). With the loop in-process (ADR 0005 Track D) this is the
    /// `LoopEngine`, which calls the loop directly; commands route through it. (Named `bridge` to
    /// avoid clashing with the `connection: ConnectionState` UI property.)
    @ObservationIgnored var bridge: (any CommandSink)?

    /// Notifies the app when listening starts/stops (so the HUD can come up/down optimistically).
    @ObservationIgnored var onListeningChanged: ((Bool) -> Void)?

    /// Brings the Home dashboard window forward (the rail's ⤢ button + the menu's "Open Home").
    /// A local UI action — `.openHome` must not depend on the engine round-trip.
    @ObservationIgnored var onOpenHome: (() -> Void)?

    /// Routes a menu "View Activity" selection into the dashboard model (which owns the selected
    /// agent + its own engine `selectSession` send). Local so the inspector binds immediately,
    /// rather than waiting on an engine round-trip that never comes in mock mode.
    @ObservationIgnored var onSelectSession: ((String) -> Void)?

    /// Opens the dashboard on its Settings tab (the menu "Settings…"). Local UI action.
    @ObservationIgnored var onOpenSettings: (() -> Void)?
    func openSettings() { onOpenSettings?() }

    /// Send a command; some are local UI actions (listening flag, open Home, select) applied
    /// optimistically and NOT re-forwarded here (the owning model forwards its own).
    func send(_ command: Command) {
        switch command {
        case .startListening: isListening = true; onListeningChanged?(true)
        case .stopListening: isListening = false; onListeningChanged?(false)
        case .openHome: onOpenHome?()
        case let .selectSession(id): onSelectSession?(id); return // HomeDashboardModel owns + forwards this
        default: break
        }
        guard let bridge else { return }
        Task { await bridge.send(command) }
    }

    // MARK: Frame application

    func apply(_ frame: BridgeFrame) {
        switch frame {
        case let .state(topic, readiness):
            guard topic == "readiness", let readiness else { return }
            self.readiness = readiness.capabilities
            recomputeReadiness()
        case let .sessions(payload):
            sessions = payload.sessions.map(MenuSession.init)
            counts = payload.resolvedCounts
            pausedSessionIds.formIntersection(Set(sessions.map(\.id))) // drop agents that are gone
        case let .runResult(result):
            applyRunResult(result)
        case .cursor, .transcript, .referents, .intent, .audit, .gaze, .error, .unknown:
            break // the menu surface does not consume these (HUD/overlays do)
        }
    }

    func setConnection(_ state: ConnectionState) {
        connection = state
        canListen = Self.canListen(caps: readiness, connection: state)
        if state != .connected, sessions.isEmpty { readinessLabel = Self.connectionLabel(state) }
    }

    private func applyRunResult(_ result: RunResultPayload) {
        guard let sessionId = result.sessionId,
              let index = sessions.firstIndex(where: { $0.id == sessionId }) else { return }
        let existing = sessions[index]
        sessions[index] = MenuSession(
            id: existing.id, title: existing.title, agentLabel: existing.agentLabel,
            status: result.status, startedAt: existing.startedAt
        )
        counts = SessionCounts(derivingStatuses: sessions.map(\.status))
    }

    private func recomputeReadiness() {
        menuReadiness = Self.readinessLevel(for: readiness)
        readinessLabel = Self.readinessLabel(for: menuReadiness)
        canListen = Self.canListen(caps: readiness, connection: connection)
    }

    // MARK: Pure derivations (nonisolated → unit-tested without the main actor)

    /// Capabilities Director needs to listen. Worst state wins; missing == attention.
    nonisolated static let listenCapabilities = ["microphone", "speech-recognition"]

    nonisolated static func readinessLevel(for caps: [CapabilityProbe]) -> ReadinessLevel {
        var level = ReadinessLevel.ready
        for id in listenCapabilities {
            switch caps.first(where: { $0.id == id })?.state {
            case "granted", "running":
                continue
            case "denied", "restricted", "not-installed", "stopped":
                return .blocked
            default: // not-determined, unknown, or missing
                level = .attention
            }
        }
        return level
    }

    nonisolated static func readinessLabel(for level: ReadinessLevel) -> String {
        switch level {
        case .ready: return "Listening ready"
        case .attention: return "Attention"
        case .blocked: return "Blocked"
        }
    }

    nonisolated static func connectionLabel(_ state: ConnectionState) -> String {
        switch state {
        case .connecting: return "Connecting to engine…"
        case .connected: return "Connected"
        case .reconnecting: return "Reconnecting…"
        case .engineDown: return "Director engine not running"
        }
    }

    nonisolated static func canListen(caps: [CapabilityProbe], connection: ConnectionState) -> Bool {
        guard connection == .connected else { return false }
        let granted: (String) -> Bool = { id in
            let state = caps.first(where: { $0.id == id })?.state
            return state == "granted" || state == "running"
        }
        return granted("microphone") && granted("speech-recognition")
    }

    nonisolated static func parseISO(_ string: String) -> Date? {
        isoParserFractional.date(from: string) ?? isoParserPlain.date(from: string)
    }
}

// File-scope (nonisolated) ISO parsers so the pure derivations stay main-actor-free.
private let isoParserFractional: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
}()
private let isoParserPlain = ISO8601DateFormatter()
