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
    /// The live AX/driver window set the bus ranks each hit against (FR-4).
    let screen: ScreenSnapshotProvider
    /// The live consumer of the bus's fusion ring — the fused "what is the user pointing at" answer.
    let aligner: PointingAligner
    private let facePlugin: FaceModelPlugin
    private let handPlugin: HandModelPlugin

    /// Async source of the live driver window list (`CuaDriverService.listWindows()`), polled off the
    /// camera path while sensing to refresh `screen`. Nil → no live ranking (tests / no-driver hosts).
    private let windowSource: (() async -> [CuaWindow])?
    private let pollInterval: Duration
    private var pollTask: Task<Void, Never>?

    /// Hand cursor → bridge `cursorPosition`. Delivered on the MAIN thread.
    var onCursorPosition: ((CursorPositionPayload) -> Void)?
    /// Face gaze → bridge `gazeFocus`. Delivered on the MAIN thread.
    var onGazeFocus: ((GazeFocus) -> Void)?
    /// Face point → `HeadPointSnapshot` intent evidence. Delivered off-main (snapshot is locked).
    var onFaceEvidence: ((HeadPoint) -> Void)?
    /// Hand cursor → `GestureSnapshot` intent evidence. Delivered off-main (snapshot is locked).
    var onHandEvidence: ((GestureReferent) -> Void)?

    /// - Parameters:
    ///   - screenProvider: maps normalized perception output to screen pixels. Defaults to the
    ///     multi-display UNION bounds (the whole virtual desktop) captured once at construction
    ///     (avoids off-main `NSScreen` reads on the plugin queues); pass an explicit provider for
    ///     dynamic geometry.
    ///   - windowSource: async driver window list, polled while sensing to feed the NBest ranker.
    ///   - calibration: the per-display SL-2 hand fit (RB-3), reconstructed from a persisted
    ///     `CalibrationProfile`. `nil` (default) keeps the uncalibrated `ActiveRegion` hand path.
    init(
        screenProvider: (() -> CGRect)? = nil,
        windowSource: (() async -> [CuaWindow])? = nil,
        calibration: CalibrationFit? = nil,
        pollInterval: Duration = .milliseconds(500)
    ) {
        let provider: () -> CGRect
        if let screenProvider {
            provider = screenProvider
        } else {
            let bounds = Self.unionDisplayBounds()
            provider = { bounds }
        }

        let screen = ScreenSnapshotProvider()
        self.screen = screen
        self.windowSource = windowSource
        self.pollInterval = pollInterval

        let hand = HandModelPlugin(calibration: calibration, screenProvider: provider)
        let face = FaceModelPlugin(screenProvider: provider)
        self.handPlugin = hand
        self.facePlugin = face
        self.bus = PerceptionBus(plugins: [hand, face], screenProvider: { [screen] in screen.current() })
        self.aligner = PointingAligner(ring: bus.ring)
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

    /// Bring the one camera up or down (push-to-talk gating). While sensing, a background poll keeps
    /// the AX/driver window snapshot fresh so the NBest ranker has a current candidate set.
    func setSensing(_ on: Bool) {
        if on {
            camera.start()
            startWindowPoll()
        } else {
            camera.stop()
            stopWindowPoll()
        }
    }

    /// Host shutdown.
    func teardown() {
        camera.stop()
        stopWindowPoll()
    }

    /// Poll the driver window list on `pollInterval` and refresh `screen`. No-op without a source.
    private func startWindowPoll() {
        guard let windowSource, pollTask == nil else { return }
        let screen = self.screen
        let interval = self.pollInterval
        // Captures only the unwrapped source + locals (no `self`) — no retain cycle via pollTask.
        pollTask = Task {
            while !Task.isCancelled {
                screen.update(windows: await windowSource())
                try? await Task.sleep(for: interval)
            }
        }
    }

    private func stopWindowPoll() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// The multi-display UNION bounds in canonical CG top-left space — the whole virtual desktop the
    /// perception cursor/gaze maps across (the plugins' `screenProvider` contract).
    ///
    /// Each `NSScreen.frame` is Cocoa (bottom-left origin, y up); it is flipped to CG top-left with
    /// the menu-bar screen height `h0 = NSScreen.screens.first.frame.height` — `NSScreen.screens.first`
    /// (the primary/menu-bar display), NOT `NSScreen.main` (the key-window screen, which drifts with
    /// focus — see CoordinateSpace.swift) — then `DisplayMap.unionBounds` takes the bounding box, so
    /// a secondary display above/left of the primary contributes a negative origin (CLAUDE.md I7).
    /// Single-display reduces to `(0, 0, w, h)` — identical to the old primary-only default.
    static func unionDisplayBounds() -> CGRect {
        let screens = NSScreen.screens
        guard let primary = screens.first else { return CGRect(x: 0, y: 0, width: 1920, height: 1080) }
        return unionBounds(ofCocoaFrames: screens.map(\.frame), menuBarHeight: primary.frame.height)
    }

    /// Pure composition (headless-testable): flip each Cocoa frame to CG top-left with the menu-bar
    /// height, then take the union bounding box. `NSScreen` is read only by the caller above.
    static func unionBounds(ofCocoaFrames cocoaFrames: [CGRect], menuBarHeight h0: CGFloat) -> CGRect {
        DisplayMap.unionBounds(cocoaFrames.map { CoordinateSpace.flipRect($0, h0: h0) })
    }
}
