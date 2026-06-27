import XCTest
import CoreVideo
import CoreGraphics
@testable import DirectorSidecar

/// S2·T7 — the concurrent PerceptionBus replaces `ModelHost`'s one-active-model rule. A single
/// `route(frame)` FANS OUT to ALL perception plugins (face + hand every frame, on per-plugin serial
/// queues — no `onPointer` main-thread hop), each producing ONE `PointingEvent` into the shared
/// 300ms ring per frame, and driving the publisher per modality. `ModelHost` is demoted to the
/// overlay model-picker only. (RESEARCH_CONVERGENCE §7; MIGRATION §8; CLAUDE I5 in-process.)
final class PerceptionBusTests: XCTestCase {

    /// A spy perception plugin that counts frames and emits a canned output (live by default).
    private final class SpyPerceptionPlugin: PerceptionPlugin {
        let perceptionSource: EventSource
        private let point: CGPoint
        private let state: PointerOutput.State
        private(set) var frameCount = 0
        var latestOutput: PointerOutput?
        init(source: EventSource, point: CGPoint, state: PointerOutput.State = .live) {
            self.perceptionSource = source
            self.point = point
            self.state = state
        }
        func process(_ frame: FrameSample) -> FrameSample {
            frameCount += 1
            latestOutput = PointerOutput(point: point, state: state, confidence: 0.9)
            return frame
        }
    }

    /// A `ScreenEvent` whose single window `id` frames the rect — the candidate NBestCluster ranks.
    private func screen(id: String, _ rect: CGGlobalRect) -> ScreenEvent {
        ScreenEvent(
            header: EventHeader(source: .screen_ax, tSrc: MonotonicInstant(nanoseconds: 0),
                                conf: 1, nBest: 0, taint: .trusted),
            windows: [PerceptionWindowRef(appBundleId: id, title: id, frame: rect, display: 0)],
            displays: [], focusedField: nil)
    }

    private func makePixelBuffer() -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, 8, 8,
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, nil, &pb)
        precondition(status == kCVReturnSuccess)
        return pb!
    }

    func test_route_fansOutToAllPlugins_oneEventPerPluginPerFrame() {
        let face = SpyPerceptionPlugin(source: .face_gaze, point: CGPoint(x: 10, y: 20))
        let hand = SpyPerceptionPlugin(source: .hand_pose, point: CGPoint(x: 30, y: 40))
        let bus = PerceptionBus(plugins: [face, hand])

        bus.route(FrameSample(tCapture: 1.0, pixelBuffer: makePixelBuffer()))
        bus.waitUntilIdle()

        XCTAssertEqual(face.frameCount, 1, "fan-out: face sees the frame")
        XCTAssertEqual(hand.frameCount, 1, "fan-out: hand ALSO sees the SAME frame (NOT one-active)")

        let events = bus.ring.within(window: 10_000, now: PointingEventAdapter.monotonicNow())
        XCTAssertEqual(events.count, 2, "one PointingEvent per plugin per frame")
        XCTAssertEqual(Set(events.map(\.header.source)), [.face_gaze, .hand_pose])
    }

    func test_route_drivesPublisherPerModality_noReflip() {
        let hand = SpyPerceptionPlugin(source: .hand_pose, point: CGPoint(x: 640, y: 880))
        let bus = PerceptionBus(plugins: [hand])
        var cursor: CursorPositionPayload?
        bus.onCursorPosition = { cursor = $0 }

        bus.route(FrameSample(tCapture: 1.0, pixelBuffer: makePixelBuffer()))
        bus.waitUntilIdle()

        XCTAssertEqual(cursor?.pointers.first?.x, 640)
        XCTAssertEqual(cursor?.pointers.first?.y, 880, "published through the bus unchanged (N2)")
        XCTAssertEqual(cursor?.pointers.first?.kind, "user")
    }

    func test_faceModality_drivesGazeFocusSink() throws {
        let face = SpyPerceptionPlugin(source: .face_gaze, point: CGPoint(x: 500, y: 400))
        let bus = PerceptionBus(plugins: [face])
        var gaze: GazeFocus?
        bus.onGazeFocus = { gaze = $0 }

        bus.route(FrameSample(tCapture: 1.0, pixelBuffer: makePixelBuffer()))
        bus.waitUntilIdle()

        let focus = try XCTUnwrap(gaze)
        XCTAssertEqual(focus.confidence, 0.9, accuracy: 1e-9, "live face passes its confidence through")
        XCTAssertEqual(focus.bounds.x, 390) // 500 − 220/2 (default region)
    }

    func test_multipleFrames_eachFansOutToEachPlugin() {
        let hand = SpyPerceptionPlugin(source: .hand_pose, point: CGPoint(x: 1, y: 1))
        let bus = PerceptionBus(plugins: [hand])
        for _ in 0..<3 { bus.route(FrameSample(tCapture: 1.0, pixelBuffer: makePixelBuffer())) }
        bus.waitUntilIdle()
        XCTAssertEqual(hand.frameCount, 3, "every frame fans out to every plugin")
    }

    // MARK: - NBest ranking (FR-4) — the perception point→window wiring

    func test_route_ranksScreenHit_populatesNBestInRingEvent() throws {
        // Hand point (500,400) lands at the exact center of the window → ranked, conf ~1.
        let hand = SpyPerceptionPlugin(source: .hand_pose, point: CGPoint(x: 500, y: 400))
        let win = screen(id: "win.textedit", CGGlobalRect(x: 0, y: 0, width: 1000, height: 800))
        let bus = PerceptionBus(plugins: [hand], screenProvider: { win })

        bus.route(FrameSample(tCapture: 1.0, pixelBuffer: makePixelBuffer()))
        bus.waitUntilIdle()

        let event = try XCTUnwrap(bus.ring.within(window: 10_000, now: PointingEventAdapter.monotonicNow()).first)
        XCTAssertEqual(event.nBestTargets.map(\.id), ["win.textedit"], "the window under the hit leads the cluster")
        XCTAssertEqual(event.nBestTargets.first?.conf ?? 0, 1.0, accuracy: 1e-9, "dead-center hit scores ~1")
        XCTAssertEqual(event.header.nBest, 1, "header n_best reflects the cluster size")
    }

    func test_route_noScreenProvider_leavesNBestEmpty() throws {
        let hand = SpyPerceptionPlugin(source: .hand_pose, point: CGPoint(x: 500, y: 400))
        let bus = PerceptionBus(plugins: [hand]) // no provider → pre-wire behavior
        bus.route(FrameSample(tCapture: 1.0, pixelBuffer: makePixelBuffer()))
        bus.waitUntilIdle()
        let event = try XCTUnwrap(bus.ring.within(window: 10_000, now: PointingEventAdapter.monotonicNow()).first)
        XCTAssertTrue(event.nBestTargets.isEmpty, "no window source → empty cluster")
    }

    func test_route_frozenFrame_doesNotRank() throws {
        // A frozen (dropout) frame must not assert a fresh referent even with a window under it (I6).
        let hand = SpyPerceptionPlugin(source: .hand_pose, point: CGPoint(x: 500, y: 400), state: .frozen)
        let win = screen(id: "win.textedit", CGGlobalRect(x: 0, y: 0, width: 1000, height: 800))
        let bus = PerceptionBus(plugins: [hand], screenProvider: { win })
        bus.route(FrameSample(tCapture: 1.0, pixelBuffer: makePixelBuffer()))
        bus.waitUntilIdle()
        let event = try XCTUnwrap(bus.ring.within(window: 10_000, now: PointingEventAdapter.monotonicNow()).first)
        XCTAssertTrue(event.nBestTargets.isEmpty, "frozen frame asserts no cluster (I6)")
    }

    // MARK: - bias (FR-19) — confirmed-selection learning + correction

    func test_confirmSelection_movesBias_thenCorrectShiftsTowardActual() {
        let hand = SpyPerceptionPlugin(source: .hand_pose, point: .zero)
        let bus = PerceptionBus(plugins: [hand])
        XCTAssertEqual(bus.currentBias.correct(PixelPoint(x: 100, y: 100)), PixelPoint(x: 100, y: 100),
                       "starts at zero offset (identity)")
        // Confirmed: predicted (100,100) but the true target was (120,90) → offset learns (+20,−10)·0.3.
        bus.confirmSelection(predicted: PixelPoint(x: 100, y: 100), actual: PixelPoint(x: 120, y: 90))
        let corrected = bus.currentBias.correct(PixelPoint(x: 100, y: 100))
        XCTAssertEqual(corrected.x, 106, accuracy: 1e-9) // 100 + 0.3·20
        XCTAssertEqual(corrected.y, 97, accuracy: 1e-9)  // 100 + 0.3·(−10)
    }

    func test_route_appliesLearnedBiasBeforeRanking() throws {
        // The raw hit (590,400) is 90px right of a 100-wide window at x∈[0,100] → outside default
        // radius 24 → no cluster. After a confirmed selection teaches a strong leftward offset, the
        // CORRECTED hit lands back inside the window → ranked. Proves route ranks the corrected hit.
        let hand = SpyPerceptionPlugin(source: .hand_pose, point: CGPoint(x: 590, y: 50))
        let win = screen(id: "win.left", CGGlobalRect(x: 0, y: 0, width: 100, height: 100))
        let bus = PerceptionBus(plugins: [hand], screenProvider: { win })

        // Teach: predicted far-right, actual at the window → large negative-x offset (EMA·0.3 each).
        for _ in 0..<40 {
            bus.confirmSelection(predicted: PixelPoint(x: 590, y: 50), actual: PixelPoint(x: 50, y: 50))
        }
        bus.route(FrameSample(tCapture: 1.0, pixelBuffer: makePixelBuffer()))
        bus.waitUntilIdle()

        let event = try XCTUnwrap(bus.ring.within(window: 10_000, now: PointingEventAdapter.monotonicNow()).first)
        XCTAssertEqual(event.nBestTargets.map(\.id), ["win.left"],
                       "the bias-corrected hit lands inside the window → ranked")
    }
}
