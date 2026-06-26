//
//  ServiceCoordinator.swift
//  DirectorSidecar
//
//  Track F (ADR 0005). Binds the ported engine services (`DirectorServices`) to the app lifecycle:
//
//    app launch        → start()        : begin consuming head-pointer events for the app's life
//    listening on/off  → setSensing(_:) : front-camera head pointer + on-device mic UP / DOWN
//    app terminate     → teardown()     : stop sensing, finish the head stream, cancel consumers
//
//  The head pointer's `.point` events are projected onto the bridge `cursorPosition` topic
//  (`HeadPointerBridge.pointer(from:)`) and handed to `onHeadPointer`, which the app feeds into the
//  same frame fan-out the engine bridge uses — so a real (non-mock) run drives the Director
//  `.user` cursor from the user's head, exactly as `HeadPointerEvent.swift` anticipated.
//
//  Speech events flow to `onSpeech`. The transcript CONSUMER (intent resolution) is the LLM-loop
//  port (PORTING.md § Porting Order 3) — Track F owns only the mic's *lifecycle* (up/down with
//  listening, clean teardown) and the typed seam, so the loop port attaches a consumer without
//  re-owning the AVAudioEngine lifecycle.
//
//  The coordinator depends on the `HeadSensing` / `SpeechStreaming` protocols (not the concrete
//  services) purely so the lifecycle can be unit-tested with fakes — a camera/mic can't run under
//  headless `xcodebuild`. The real services conform retroactively below.
//

import Foundation
import OSLog

// MARK: - Injection seams (so the lifecycle is testable without a camera/mic)

/// The head-pointer facade the coordinator drives. `HeadPointerService` already has this exact
/// surface; the protocol exists only to inject a fake under test.
@MainActor
protocol HeadSensing: AnyObject {
    /// Typed event feed (start/point/stopped/error in emission order).
    nonisolated var events: AsyncStream<HeadPointerEvent> { get }
    /// Turn the camera capture session on. Idempotent (a second call while running is a no-op).
    func start()
    /// Turn the camera capture session off. The `events` stream stays open for a later `start()`.
    func stop()
    /// Permanently stop and finish the `events` stream (host teardown).
    func finish()
}

/// The on-device STT facade the coordinator drives. `SpeechService.OnDeviceStream` already matches.
@MainActor
protocol SpeechStreaming: AnyObject {
    /// Begin a recognition session and return its event stream (ready/partial/final/error).
    func start() -> AsyncStream<SpeechService.Event>
    /// End the current recognition session.
    func stop()
}

extension HeadPointerService: HeadSensing {}
extension SpeechService.OnDeviceStream: SpeechStreaming {}

// MARK: - Head point → cursor projection (pure, unit-tested)

/// Projects a head-pointer `HeadPoint` onto the bridge `cursorPosition` wire `Pointer` — the single
/// `.user` Director cursor. Pure so it is testable without a camera. The head point is ALREADY in
/// contract space (virtual-desktop px, top-left origin, y-down — flipped at emission via
/// `HeadGeometry.appKitToGlobalTopLeft`), so x/y pass straight through with no re-flip.
enum HeadPointerBridge {
    /// The single user reticle id the overlay reducer keys on (`OverlayModel.userId`). A `Pointer`'s
    /// `id` is `agentId ?? kind`, so a `kind == "user"` pointer with no `agentId` resolves to "user".
    static let userKind = "user"
    static let space = "virtual-desktop-px"

    static func pointer(from head: HeadPoint) -> Pointer {
        // A live head point means the user is actively pointing → `moving` (a target the Director
        // cursor travels to). At-rest "stopped pointing" is the absence of points, which the overlay
        // already handles by leaving the cursor hugging the system cursor.
        Pointer(
            x: head.x,
            y: head.y,
            space: space,
            kind: userKind,
            agentId: nil,
            agentLabel: nil,
            state: "moving",
            confidence: head.confidence,
            ts: Double(head.ts)
        )
    }
}

// MARK: - Coordinator

@MainActor
final class ServiceCoordinator {
    private let head: any HeadSensing
    private let speech: any SpeechStreaming
    private let onHeadPointer: (Pointer) -> Void
    private let onSpeech: (SpeechService.Event) -> Void

    private var headConsumer: Task<Void, Never>?
    private var speechConsumer: Task<Void, Never>?

    /// True between `setSensing(true)` and `setSensing(false)` — the camera/mic are up.
    private(set) var isSensing = false
    /// True once `teardown()` has run; further lifecycle calls are inert (no resurrecting a torn-down
    /// app on a late notification).
    private(set) var isTornDown = false

    init(
        head: any HeadSensing,
        speech: any SpeechStreaming,
        onHeadPointer: @escaping (Pointer) -> Void,
        onSpeech: @escaping (SpeechService.Event) -> Void = { _ in }
    ) {
        self.head = head
        self.speech = speech
        self.onHeadPointer = onHeadPointer
        self.onSpeech = onSpeech
    }

    /// Convenience: build from the concrete service container.
    convenience init(
        services: DirectorServices,
        onHeadPointer: @escaping (Pointer) -> Void,
        onSpeech: @escaping (SpeechService.Event) -> Void = { _ in }
    ) {
        self.init(head: services.headPointer, speech: services.speech,
                  onHeadPointer: onHeadPointer, onSpeech: onSpeech)
    }

    // MARK: Lifecycle

    /// Begin consuming the head-pointer event feed for the app's whole life. The camera itself stays
    /// off until `setSensing(true)`; this only wires the consumer so `.point` events (once sensing
    /// starts) flow to `onHeadPointer`. Idempotent.
    func start() {
        guard headConsumer == nil, !isTornDown else { return }
        DirectorDiagnostics.services.info("service coordinator started")
        let events = head.events  // captured on the main actor; AsyncStream<HeadPointerEvent> is Sendable
        headConsumer = Task { [weak self] in
            for await event in events {
                await self?.handle(event)
            }
        }
    }

    /// Bring the front-camera head pointer and on-device mic up (`on == true`) or down. No-op if the
    /// state is unchanged or the coordinator is torn down.
    func setSensing(_ on: Bool) {
        guard on != isSensing, !isTornDown else { return }
        isSensing = on
        if on {
            DirectorDiagnostics.services.info("sensing on")
            head.start()
            startSpeech()
        } else {
            DirectorDiagnostics.services.info("sensing off")
            head.stop()
            stopSpeech()
        }
    }

    /// Host teardown: stop sensing, finish the head stream (which ends the consumer), cancel tasks.
    /// Idempotent — safe to call from both a `willTerminate` notification and an explicit shutdown.
    func teardown() {
        guard !isTornDown else { return }
        DirectorDiagnostics.services.info("service coordinator teardown")
        isTornDown = true
        if isSensing {
            head.stop()
            stopSpeech()
            isSensing = false
        }
        head.finish()
        headConsumer?.cancel()
        headConsumer = nil
    }

    // MARK: Internals

    private func handle(_ event: HeadPointerEvent) {
        switch event {
        case let .point(point):
            DirectorDiagnostics.services.debug("head point x=\(point.x, privacy: .public) y=\(point.y, privacy: .public) confidence=\(point.confidence, privacy: .public)")
            onHeadPointer(HeadPointerBridge.pointer(from: point))
        case .started:
            DirectorDiagnostics.services.info("head pointer started")
        case .stopped:
            DirectorDiagnostics.services.info("head pointer stopped")
        case let .error(message, _):
            DirectorDiagnostics.services.error("head pointer error \(message, privacy: .public)")
            // Lifecycle/error events are the head service's own concern; the cursor path only needs
            // points. (A future surface could reflect `.error` as a degraded-readiness signal.)
            break
        }
    }

    private func startSpeech() {
        DirectorDiagnostics.services.info("speech stream start")
        speechConsumer?.cancel()
        let stream = speech.start()
        speechConsumer = Task { [weak self] in
            for await event in stream {
                await self?.deliverSpeech(event)
            }
        }
    }

    private func stopSpeech() {
        DirectorDiagnostics.services.info("speech stream stop")
        speech.stop()
        speechConsumer?.cancel()
        speechConsumer = nil
    }

    private func deliverSpeech(_ event: SpeechService.Event) {
        onSpeech(event)
    }
}
