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
// Screen mapping (MULTI-MONITOR): the perception plugins map their normalized [0,1] output into the
// rect `screenProvider` returns. The default spans the FULL virtual desktop — the union of EVERY
// connected display, flipped to canonical CG top-left (`screenUnionCG`) — so face/hand reach every
// monitor (incl. displays at negative origins), not just the primary. The union is cached behind a
// lock and refreshed on `didChangeScreenParametersNotification`, so (a) the off-main plugin queue
// never touches `NSScreen`, and (b) hot-plugging or rearranging a monitor updates the reachable area
// live, without a relaunch.
//
// Threading: the bus fires its callbacks on the per-plugin queues (off-main). The two BRIDGE
// callbacks (`onCursorPosition` / `onGazeFocus`) are marshaled to the main thread here, because the
// app dispatches bridge frames on the main actor. The two INTENT callbacks write lock-protected
// snapshots and stay off-main. Wire all four callbacks BEFORE `setSensing(true)` so the camera does
// not race callback assignment.

import AppKit
import CoreGraphics
import Foundation

/// Thread-safe holder for the display-union rect, so the off-main plugin queues read a plain value
/// each frame instead of touching `NSScreen` off the main thread. Updated on the main queue when the
/// screen layout changes.
private final class ScreenUnionCache: @unchecked Sendable {
    private let lock = NSLock()
    private var rect: CGRect
    init(_ rect: CGRect) { self.rect = rect }
    var value: CGRect { lock.lock(); defer { lock.unlock() }; return rect }
    func set(_ newRect: CGRect) { lock.lock(); rect = newRect; lock.unlock() }
}

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

    private let screenCache: ScreenUnionCache
    private var screenObserver: NSObjectProtocol?

    /// - Parameter screenProvider: maps normalized perception output to screen pixels. Defaults to
    ///   the FULL multi-monitor union (every connected display), so face/hand span all monitors and
    ///   follow live layout changes. Pass an explicit provider to override (e.g. tests, or to pin a
    ///   single display).
    init(screenProvider: (() -> CGRect)? = nil) {
        let cache = ScreenUnionCache(Self.screenUnionCG())
        self.screenCache = cache

        // Capture the cache (not `self`) so the plugin queues read the union without touching
        // `NSScreen` off-main and without a self-capture-before-init.
        let provider: () -> CGRect = screenProvider ?? { cache.value }

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

        // Follow monitor hot-plug / rearrangement so the reachable area tracks the live layout.
        // Recomputed on the main queue (where `NSScreen` is read); the cache makes the new value
        // visible to the off-main plugin queues.
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { _ in cache.set(PerceptionService.screenUnionCG()) }
    }

    deinit {
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
    }

    /// Lifecycle parity with the services it replaces. The camera comes up on `setSensing`.
    func start() {}

    /// Bring the one camera up or down (push-to-talk gating).
    func setSensing(_ on: Bool) {
        if on { camera.start() } else { camera.stop() }
    }

    /// Host shutdown.
    func teardown() { camera.stop() }

    /// Fallback when no displays are reported (headless / first paint).
    static let fallbackBounds = CGRect(x: 0, y: 0, width: 1920, height: 1080)

    /// The live display union across ALL connected monitors, in canonical CG **top-left**
    /// (virtual-desktop-px) coordinates — the space the bridge publishes in. Mirrors HO-rebuild's
    /// `EngineRuntime.screenUnionCG`: take the Cocoa (bottom-left) union of every screen frame, then
    /// flip about the primary screen height `h0` so displays at negative origins map correctly and
    /// the reachable area covers the whole desktop. Read on the main thread only.
    static func screenUnionCG() -> CGRect {
        let frames = NSScreen.screens.map(\.frame)
        guard !frames.isEmpty else { return fallbackBounds }
        let cocoa = DisplayMap.unionBounds(frames)
        let h0 = NSScreen.screens.first?.frame.height ?? cocoa.height
        return CGRect(x: cocoa.minX, y: h0 - cocoa.maxY, width: cocoa.width, height: cocoa.height)
    }
}
