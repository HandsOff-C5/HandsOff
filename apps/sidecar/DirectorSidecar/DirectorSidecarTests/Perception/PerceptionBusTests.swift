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

    /// A spy perception plugin that counts frames and emits a canned live output.
    private final class SpyPerceptionPlugin: PerceptionPlugin {
        let perceptionSource: EventSource
        private let point: CGPoint
        private(set) var frameCount = 0
        var latestOutput: PointerOutput?
        init(source: EventSource, point: CGPoint) {
            self.perceptionSource = source
            self.point = point
        }
        func process(_ frame: FrameSample) -> FrameSample {
            frameCount += 1
            latestOutput = PointerOutput(point: point, state: .live, confidence: 0.9)
            return frame
        }
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
}
