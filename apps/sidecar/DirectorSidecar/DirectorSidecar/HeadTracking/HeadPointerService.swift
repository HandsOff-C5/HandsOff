//
//  HeadPointerService.swift
//  DirectorSidecar
//
//  Folded in from src-tauri/sidecars/head-track/{HeadTracker,main}.swift (ADR 0005 step 5). The
//  in-process replacement for the `head-track` sidecar binary: owns the front-camera AVCaptureSession,
//  per-frame Vision face/landmark detection, the head-tracking model, and the golden overlay. This is
//  the `headPointer` slot in PORTING.md's DirectorServices shape.
//
//  Two seams from the sidecar are DELETED, not ported:
//   - stdout JSON (EventWriter)  → `events: AsyncStream<HeadPointerEvent>` (Tauri events → AsyncStream).
//   - stdin control (startControlReader / parseControlCommand) → typed `applyConfig` / `requestRecenter`.
//  The Rust host (head_track.rs: spawn, generation guard, stdout line buffering) is deleted with the
//  process boundary. Auto-start-on-launch is also gone: the host calls `start()` / `stop()` directly.
//
//  Concurrency: this type manages its own threading exactly as the sidecar did — a session queue, a
//  video queue (also the capture delegate queue), and an NSLock over the start/stop state — so it opts
//  out of the project's default MainActor isolation (`nonisolated`). The only main-actor work is
//  reading NSScreen and driving the overlay; both happen inside `MainActor.assumeIsolated` on a
//  DispatchQueue.main block, which is the main actor's executor.
//

import AppKit
import AVFoundation
import CoreGraphics
import QuartzCore
import Vision

// Swift 6.0 / default-MainActor isolation has no `nonisolated class`, so each member opts out
// individually: the methods are `nonisolated`, and the self-synchronized mutable state (serialized on
// the session/video queues + stateLock, exactly as the sidecar did) is `nonisolated(unsafe)`. The
// only MainActor-isolated member is `overlay`, reached via MainActor.assumeIsolated on a main block.
final class HeadPointerService: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    /// Typed event feed replacing the sidecar's stdout wire. Start/stop/point/error in emission order.
    nonisolated let events: AsyncStream<HeadPointerEvent>

    private nonisolated let continuation: AsyncStream<HeadPointerEvent>.Continuation
    @MainActor private lazy var overlay = HeadPointerCursorOverlay()
    private nonisolated let sessionQueue = DispatchQueue(label: "com.handsoff.headtrack.session")
    private nonisolated let videoQueue = DispatchQueue(label: "com.handsoff.headtrack.video")
    private nonisolated let minFrameInterval = 1.0 / 30.0
    private nonisolated let visionOrientation: CGImagePropertyOrientation = .upMirrored
    private nonisolated let stateLock = NSLock()
    private nonisolated(unsafe) var session: AVCaptureSession?
    private nonisolated(unsafe) var wantsRunning = false
    private nonisolated(unsafe) var running = false
    private nonisolated(unsafe) var lastFrameTime = 0.0
    private nonisolated(unsafe) var trackingModel = HeadTrackingModel()

    nonisolated override init() {
        (events, continuation) = AsyncStream<HeadPointerEvent>.makeStream()
        super.init()
    }

    // MARK: Control surface (replaces stdin protocol)

    nonisolated func start() {
        guard requestStart() else { return }

        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            startAuthorized()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                guard let self else { return }
                if granted {
                    self.startAuthorized()
                } else {
                    self.clearState()
                    self.emitError("Camera access denied")
                }
            }
        case .denied, .restricted:
            clearState()
            emitError("Camera access denied")
        @unknown default:
            clearState()
            emitError("Unknown camera authorization status")
        }
    }

    nonisolated func stop() {
        let hadStarted = requestStop()
        DispatchQueue.main.async { MainActor.assumeIsolated { self.overlay.hide() } }
        guard hadStarted else { return }
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.session?.stopRunning()
            self.session = nil
            self.continuation.yield(.stopped(ts: HeadPointerEvent.epochMillis()))
        }
    }

    nonisolated func applyConfig(_ config: HeadPointerConfig) {
        videoQueue.async { [weak self] in
            self?.trackingModel.applyConfig(config)
        }
    }

    nonisolated func requestRecenter() {
        videoQueue.async { [weak self] in
            self?.trackingModel.requestRecenter()
        }
    }

    /// Stop the feed permanently (e.g. on host teardown). After this the stream finishes.
    nonisolated func finish() {
        stop()
        continuation.finish()
    }

    // MARK: Session lifecycle

    private nonisolated func startAuthorized() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            guard self.shouldStartSession() else { return }
            do {
                let session = try self.makeSession()
                guard self.beginRunningIfWanted() else { return }
                self.videoQueue.sync {
                    self.trackingModel.reset()
                }
                self.session = session
                self.continuation.yield(.started(ts: HeadPointerEvent.epochMillis()))
                session.startRunning()
            } catch {
                self.clearState()
                self.emitError(error.localizedDescription)
            }
        }
    }

    private nonisolated func makeSession() throws -> AVCaptureSession {
        let session = AVCaptureSession()
        session.beginConfiguration()
        if session.canSetSessionPreset(.vga640x480) {
            session.sessionPreset = .vga640x480
        }

        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front) else {
            throw HeadPointerError.runtime("No front wide-angle camera found")
        }
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else {
            throw HeadPointerError.runtime("Cannot add front camera input")
        }
        session.addInput(input)

        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: videoQueue)
        guard session.canAddOutput(output) else {
            throw HeadPointerError.runtime("Cannot add camera video output")
        }
        session.addOutput(output)
        session.commitConfiguration()
        return session
    }

    // MARK: Capture delegate (video queue)

    nonisolated func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        let now = CACurrentMediaTime()
        guard isRunning(), now - lastFrameTime >= minFrameInterval else { return }
        lastFrameTime = now

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            emitError("Camera frame missing pixel buffer")
            return
        }

        let request = VNDetectFaceRectanglesRequest()
        request.revision = VNDetectFaceRectanglesRequestRevision3
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: visionOrientation, options: [:])

        do {
            try handler.perform([request])
        } catch {
            emitError("Vision face detection failed: \(error.localizedDescription)")
            return
        }

        let candidates = (request.results ?? []).enumerated().map { index, observation in
            FaceCandidate(
                id: "vision-\(index)",
                boundingBox: observation.boundingBox,
                confidence: Double(observation.confidence),
                observation: observation
            )
        }

        guard let chosen = trackingModel.chooseFace(from: candidates),
              let chosenObservation = chosen.observation
        else {
            trackingModel.missFace()
            return
        }

        let landmarkRequest = VNDetectFaceLandmarksRequest()
        landmarkRequest.inputFaceObservations = [chosenObservation]

        do {
            try handler.perform([landmarkRequest])
        } catch {
            trackingModel.rejectFrame()
            emitError("Vision face landmarks failed: \(error.localizedDescription)")
            return
        }

        guard let landmarkObservation = landmarkRequest.results?.first as? VNFaceObservation,
              let input = HeadLandmarks.input(from: landmarkObservation, id: chosen.id),
              let signal = extractSignal(from: input)
        else {
            trackingModel.rejectFrame()
            return
        }

        let screens = DispatchQueue.main.sync { MainActor.assumeIsolated { NSScreen.screens.map(\.frame) } }

        guard let point = trackingModel.point(for: signal, timestamp: now, screens: screens) else {
            if screens.isEmpty {
                emitError("No screens available for head-point mapping")
            }
            return
        }

        // The overlay draws in AppKit space (bottom-left); the wire point is
        // flipped to CoreGraphics top-left so it shares cua-driver's window-bounds
        // coordinate space for attention-region ranking (see appKitToGlobalTopLeft).
        DispatchQueue.main.async { MainActor.assumeIsolated { self.overlay.show(at: point) } }
        let wirePoint = HeadGeometry.appKitToGlobalTopLeft(point, screens: screens)
        continuation.yield(.point(HeadPoint(
            x: wirePoint.x, y: wirePoint.y, yaw: signal.yaw, pitch: signal.pitch,
            confidence: signal.confidence, ts: HeadPointerEvent.epochMillis()
        )))
    }

    // MARK: Start/stop state (NSLock)

    private nonisolated func emitError(_ message: String) {
        continuation.yield(.error(message: message, ts: HeadPointerEvent.epochMillis()))
    }

    private nonisolated func requestStart() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !wantsRunning else { return false }
        wantsRunning = true
        return true
    }

    private nonisolated func requestStop() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        wantsRunning = false
        let hadStarted = running
        running = false
        return hadStarted
    }

    private nonisolated func shouldStartSession() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return wantsRunning
    }

    private nonisolated func beginRunningIfWanted() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard wantsRunning else { return false }
        running = true
        return true
    }

    private nonisolated func isRunning() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return running
    }

    private nonisolated func clearState() {
        stateLock.lock()
        wantsRunning = false
        running = false
        stateLock.unlock()
    }
}

enum HeadPointerError: LocalizedError {
    case runtime(String)

    var errorDescription: String? {
        switch self {
        case .runtime(let message): return message
        }
    }
}
