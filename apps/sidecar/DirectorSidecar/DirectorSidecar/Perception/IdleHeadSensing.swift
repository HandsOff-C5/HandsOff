// IdleHeadSensing — a no-op `HeadSensing` so `ServiceCoordinator` can run SPEECH-ONLY while
// `PerceptionService` owns the camera.
//
// The face/hand migration makes `PerceptionService` the single camera owner (hand→cursor,
// face→gaze). The coordinator still owns the speech lifecycle (its `setSensing` starts/stops STT),
// but its head/hand camera lanes must NOT start a second camera. Constructing the coordinator with
// this idle head sensor (and `hand: nil`) keeps speech wired while the legacy head/hand cameras stay
// dark — without modifying `ServiceCoordinator` itself, so its tests are unaffected.

import Foundation

@MainActor
final class IdleHeadSensing: HeadSensing {
    nonisolated let events: AsyncStream<HeadPointerEvent>
    private let continuation: AsyncStream<HeadPointerEvent>.Continuation

    nonisolated init() {
        (events, continuation) = AsyncStream<HeadPointerEvent>.makeStream()
    }

    func start() {}
    func stop() {}
    func finish() { continuation.finish() }
}
