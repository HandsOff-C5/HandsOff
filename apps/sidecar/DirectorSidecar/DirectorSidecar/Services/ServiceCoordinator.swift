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
//  The head pointer's `.point` events drive TWO consumers off the one feed: they are projected onto
//  the bridge `cursorPosition` topic (`HeadPointerBridge.pointer(from:)`) and handed to
//  `onHeadPointer` for the Director `.user` cursor; AND the raw `HeadPoint` is handed to
//  `onHeadPoint`, which the app records into the shared `HeadPointSnapshot` the loop's
//  `HeadPointingIntake` reads at goal start — so a look reaches the intent, not just the on-screen
//  reticle. A real (non-mock) run thus both moves the cursor and grounds the resolver from the head.
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

/// The hand-landmarker facade the coordinator drives (the live gesture SOURCE — Vision hand pose
/// → the ported pipeline). `HandLandmarkerService` already has this exact surface; the protocol
/// exists only to inject a fake under test (a camera can't run under headless `xcodebuild`).
@MainActor
protocol HandSensing: AnyObject {
    /// Typed feed of parsed hand frames + FPS (the `LandmarkProcessor` output).
    nonisolated var events: AsyncStream<DetectionResult> { get }
    /// Turn the camera capture session on. Idempotent.
    func start()
    /// Turn the camera capture session off. The `events` stream stays open for a later `start()`.
    func stop()
    /// Permanently stop and finish the `events` stream (host teardown).
    func finish()
}

extension HeadPointerService: HeadSensing {}
extension SpeechService.OnDeviceStream: SpeechStreaming {}
extension HandLandmarkerService: HandSensing {}

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

// MARK: - Gesture referent → cursor projection (pure, unit-tested)

/// Projects a gesture `ReferentLoopResult` onto the bridge `cursorPosition` wire `Pointer` — the SAME
/// single `.user` Director cursor the head feeds (last writer wins; the coordinator arbitrates so the
/// hand takes precedence while a hand is present). The loop's `point` is already in contract space
/// (virtual-desktop px, top-left/y-down) because the app builds the loop with a normalized→screen
/// transform, so x/y pass straight through with no re-flip.
enum GestureReferentBridge {
    static func pointer(from result: ReferentLoopResult, ts: Double) -> Pointer {
        Pointer(
            x: result.point.x,
            y: result.point.y,
            space: HeadPointerBridge.space,
            kind: HeadPointerBridge.userKind,
            agentId: nil,
            agentLabel: nil,
            state: "moving",
            confidence: result.reliability,
            ts: ts
        )
    }
}

// MARK: - Coordinator

@MainActor
final class ServiceCoordinator {
    private let head: any HeadSensing
    private let speech: any SpeechStreaming
    private let onHeadPointer: (Pointer) -> Void
    private let onHeadPoint: (HeadPoint) -> Void
    private let onSpeech: (SpeechService.Event) -> Void

    // Hand-gesture lane (optional — absent in the existing lifecycle tests, which omit it). When a
    // `hand` sensor AND a `loop` are supplied, the coordinator drives the ported `ReferentLoop` off
    // the hand frames: a pointed hand moves the `.user` cursor and records a `GestureReferent` for
    // the intent intake. The hand takes precedence over the head cursor while a hand is present.
    private let hand: (any HandSensing)?
    private let loop: ReferentLoop?
    private let gestureSurfaces: [Contracts.Surface]
    private let onGesturePointer: (Pointer) -> Void
    private let onGestureReferent: (GestureReferent) -> Void

    private var headConsumer: Task<Void, Never>?
    private var speechConsumer: Task<Void, Never>?
    private var handConsumer: Task<Void, Never>?
    /// Timestamp of the last processed hand frame, for the loop's per-frame `dt`.
    private var lastHandTs: Double?
    /// True while a hand is visible this run — suppresses the head cursor so the two don't fight.
    private var handCursorActive = false

    /// True between `setSensing(true)` and `setSensing(false)` — the camera/mic are up.
    private(set) var isSensing = false
    /// True once `teardown()` has run; further lifecycle calls are inert (no resurrecting a torn-down
    /// app on a late notification).
    private(set) var isTornDown = false

    init(
        head: any HeadSensing,
        speech: any SpeechStreaming,
        hand: (any HandSensing)? = nil,
        loop: ReferentLoop? = nil,
        gestureSurfaces: [Contracts.Surface] = [],
        onHeadPointer: @escaping (Pointer) -> Void,
        onHeadPoint: @escaping (HeadPoint) -> Void = { _ in },
        onSpeech: @escaping (SpeechService.Event) -> Void = { _ in },
        onGesturePointer: @escaping (Pointer) -> Void = { _ in },
        onGestureReferent: @escaping (GestureReferent) -> Void = { _ in }
    ) {
        self.head = head
        self.speech = speech
        self.hand = hand
        self.loop = loop
        self.gestureSurfaces = gestureSurfaces
        self.onHeadPointer = onHeadPointer
        self.onHeadPoint = onHeadPoint
        self.onSpeech = onSpeech
        self.onGesturePointer = onGesturePointer
        self.onGestureReferent = onGestureReferent
    }

    /// Convenience: build from the concrete service container. Supplying a `loop` (built by the app
    /// with a screen-spanning calibration) activates the live hand-gesture lane off `services.handPointer`.
    convenience init(
        services: DirectorServices,
        loop: ReferentLoop? = nil,
        gestureSurfaces: [Contracts.Surface] = [],
        onHeadPointer: @escaping (Pointer) -> Void,
        onHeadPoint: @escaping (HeadPoint) -> Void = { _ in },
        onSpeech: @escaping (SpeechService.Event) -> Void = { _ in },
        onGesturePointer: @escaping (Pointer) -> Void = { _ in },
        onGestureReferent: @escaping (GestureReferent) -> Void = { _ in }
    ) {
        self.init(head: services.headPointer, speech: services.speech,
                  hand: services.handPointer, loop: loop, gestureSurfaces: gestureSurfaces,
                  onHeadPointer: onHeadPointer, onHeadPoint: onHeadPoint, onSpeech: onSpeech,
                  onGesturePointer: onGesturePointer, onGestureReferent: onGestureReferent)
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

        // The hand-gesture feed (when wired): drive the ported `ReferentLoop` off each parsed frame.
        if let hand, loop != nil {
            let handEvents = hand.events  // AsyncStream<DetectionResult> is Sendable
            handConsumer = Task { [weak self] in
                for await result in handEvents {
                    await self?.handleHand(result)
                }
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
            hand?.start()
            startSpeech()
        } else {
            DirectorDiagnostics.services.info("sensing off")
            head.stop()
            hand?.stop()
            handCursorActive = false
            lastHandTs = nil
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
            hand?.stop()
            stopSpeech()
            isSensing = false
        }
        head.finish()
        hand?.finish()
        headConsumer?.cancel()
        headConsumer = nil
        handConsumer?.cancel()
        handConsumer = nil
    }

    // MARK: Internals

    private func handle(_ event: HeadPointerEvent) {
        switch event {
        case let .point(point):
            DirectorDiagnostics.services.debug("head point x=\(point.x, privacy: .public) y=\(point.y, privacy: .public) confidence=\(point.confidence, privacy: .public)")
            // Two consumers off the one feed: the overlay cursor (projected to a `Pointer`) and the
            // intent — the raw head point lands in the shared snapshot the loop's HeadPointingIntake
            // reads at goal start, so a look reaches the resolver, not just the on-screen reticle.
            // Arbitration: while a hand is pointing, the HAND owns the cursor — suppress the head
            // cursor so the two feeds don't fight over the single `.user` reticle. The head still
            // grounds the intent (the snapshot) regardless.
            if !handCursorActive { onHeadPointer(HeadPointerBridge.pointer(from: point)) }
            onHeadPoint(point)
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

    /// Drive the ported gesture pipeline off one live hand frame: run it through the `ReferentLoop`,
    /// move the `.user` cursor to the wrist-ray point (taking precedence over the head while a hand
    /// is present), and record the `GestureReferent` for the intent intake. Errors are swallowed —
    /// a malformed frame must not break the feed (the loop already validated the 21-landmark shape).
    private func handleHand(_ result: DetectionResult) {
        guard let loop else { return }
        let frame = result.frame
        // Per-frame dt from the frame clock (ms); first frame falls back to a 30fps step.
        let dt = lastHandTs.map { frame.timestampMs - $0 } ?? (1000.0 / 30.0)
        lastHandTs = frame.timestampMs
        guard let loopResult = try? loop.process(frame, dt) else { return }

        // A hand present this frame (the loop sets a positive fusion weight only with a hand) owns
        // the cursor; no hand → release it so the head can drive again.
        handCursorActive = loopResult.reliability > 0
        if handCursorActive {
            onGesturePointer(GestureReferentBridge.pointer(from: loopResult, ts: frame.timestampMs))
        }
        onGestureReferent(GestureReferentFusion.referent(from: loopResult, surfaces: gestureSurfaces))
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
        // `speech.stop()` emits the final transcript (synthesized from the last partial on fn
        // release) and THEN finishes the stream. Do NOT cancel the consumer here — cancelling
        // mid-stop drops the buffered `.final` before it reaches the loop. Releasing our handle is
        // enough: the consumer drains the final and ends naturally when the finished stream closes
        // its `for await`.
        speech.stop()
        speechConsumer = nil
    }

    private func deliverSpeech(_ event: SpeechService.Event) {
        onSpeech(event)
    }
}
