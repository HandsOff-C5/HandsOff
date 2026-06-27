// PerceptionService — the one app-owned camera service for face + hand perception.
//
// Owns a single `CameraBus` (one `AVCaptureSession`) and a `PerceptionBus` that fans each frame to
// the hand and face plugins on their own serial queues. This is the replacement for the separate
// `HeadPointerService` + `HandLandmarkerService` as the live face/hand owner — those files stay on
// disk (unused), nothing is deleted.
//
// Output lanes (the migration's R4 contract):
//   • hand → `cursorPosition` (a `.user` `Pointer`) + `GestureSnapshot` intent evidence
//   • face → `gazeFocus` (a region)               + `HeadPointSnapshot` intent evidence
//
// Threading: the bus fires its callbacks on the per-plugin queues (off-main). The two BRIDGE
// callbacks (`onCursorPosition` / `onGazeFocus`) are marshaled to the main thread here, because the
// app dispatches bridge frames on the main actor. The two INTENT callbacks write lock-protected
// snapshots and stay off-main. Wire all four callbacks BEFORE `setSensing(true)` so the camera does
// not race callback assignment.

import AppKit
import CoreGraphics
import Foundation

final class PerceptionService {
    let camera: CameraBus
    let bus: PerceptionBus
    private let facePlugin: FaceModelPlugin
    private let handPlugin: HandModelPlugin

    /// Hand cursor → bridge `cursorPosition`. Delivered on the MAIN thread.
    var onCursorPosition: ((CursorPositionPayload) -> Void)?
    /// Face gaze → bridge `gazeFocus`. Delivered on the MAIN thread.
    var onGazeFocus: ((GazeFocus) -> Void)?
    /// Face point → `HeadPointSnapshot` intent evidence. Delivered off-main (snapshot is locked).
    var onFaceEvidence: ((HeadPoint) -> Void)?
    /// Hand cursor → `GestureSnapshot` intent evidence. Delivered off-main (snapshot is locked).
    var onHandEvidence: ((GestureReferent) -> Void)?

    /// - Parameter screenProvider: maps normalized perception output to screen pixels. Defaults to
    ///   the primary display bounds captured once at construction (avoids off-main `NSScreen` reads
    ///   on the plugin queues); pass an explicit provider for multi-display / dynamic geometry.
    init(screenProvider: (() -> CGRect)? = nil) {
        let provider: () -> CGRect
        if let screenProvider {
            provider = screenProvider
        } else {
            let bounds = Self.primaryDisplayBounds()
            provider = { bounds }
        }

        let hand = HandModelPlugin(screenProvider: provider)
        let face = FaceModelPlugin(screenProvider: provider)
        self.handPlugin = hand
        self.facePlugin = face
        self.bus = PerceptionBus(plugins: [hand, face])
        self.camera = CameraBus()

        bus.onCursorPosition = { [weak self] payload in
            guard let self else { return }
            DispatchQueue.main.async { self.onCursorPosition?(payload) }
        }
        bus.onGazeFocus = { [weak self] gaze in
            guard let self else { return }
            DispatchQueue.main.async { self.onGazeFocus?(gaze) }
        }
        bus.onHandOutput = { [weak self] output in
            guard let self, let referent = HandIntentAdapter.referent(from: output) else { return }
            self.onHandEvidence?(referent)
        }
        bus.onFaceOutput = { [weak self] output in
            guard let self, let head = FaceIntentAdapter.headPoint(from: output) else { return }
            self.onFaceEvidence?(head)
        }
        camera.onFrame = { [weak self] frame in self?.bus.route(frame) }
    }

    /// Lifecycle parity with the services it replaces. The camera comes up on `setSensing`.
    func start() {}

    /// Bring the one camera up or down (push-to-talk gating).
    func setSensing(_ on: Bool) {
        if on { camera.start() } else { camera.stop() }
    }

    /// Host shutdown.
    func teardown() { camera.stop() }

    /// Primary display bounds in top-left pixel space — the default screen mapping. A multi-display
    /// (`DisplayMap` union) provider is a refinement callers can inject.
    static func primaryDisplayBounds() -> CGRect {
        if let screen = NSScreen.main {
            return CGRect(origin: .zero, size: screen.frame.size)
        }
        return CGRect(x: 0, y: 0, width: 1920, height: 1080)
    }
}
