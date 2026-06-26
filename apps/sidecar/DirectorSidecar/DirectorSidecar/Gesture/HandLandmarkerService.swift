//
//  HandLandmarkerService.swift
//  DirectorSidecar
//
//  Native equivalent of packages/gesture/src/mediapipe/handLandmarker.ts — the live hand
//  landmarker. The web build instantiated MediaPipe's wasm `HandLandmarker` for VIDEO mode;
//  the native app uses Apple's Vision `VNDetectHumanHandPoseRequest`, the same framework the
//  head-track fold-in (PORTING note 6) chose for faces. Vision's 21 joints are remapped into
//  the standard MediaPipe 21-point topology so the SHARED pure pipeline downstream
//  (`LandmarkParsing` → `GesturePointing`/`GestureCalibration` → `ReferentLoop`) is reused
//  byte-for-byte — only the perception SOURCE changes, exactly the seam detector.ts defined.
//
//  Like handLandmarker.ts + HeadPointerService, this is the un-unit-tested live shell (needs a
//  camera + the bundled .app per CLAUDE.md; `tauri dev`/headless cannot drive it). The gating,
//  parsing, FPS, and error handling it relies on ARE unit-tested via the pure `LandmarkProcessor`.
//  No consumer is wired yet — the gesture→referent fusion that drives the cursor/candidate is a
//  later track (like head-track's deferred attention ranking); this lands the perception source.
//
//  Concurrency mirrors HeadPointerService exactly: Swift 6.0 / default-MainActor has no
//  `nonisolated class`, so each member opts out individually and the self-synchronized mutable
//  state (serialized on the session/video queues + an NSLock) is `nonisolated(unsafe)`.
//

import AVFoundation
import CoreGraphics
import QuartzCore
import Vision

final class HandLandmarkerService: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, LandmarkDetector, @unchecked Sendable {
    /// Typed feed of successfully parsed frames + their FPS (replaces handLandmarker.ts's rAF
    /// `onResult`). Detector/parse errors are swallowed by the processor (the loop never crashes
    /// the host), matching the TS `onError` contract.
    nonisolated let events: AsyncStream<DetectionResult>

    private nonisolated let continuation: AsyncStream<DetectionResult>.Continuation
    private nonisolated let sessionQueue = DispatchQueue(label: "com.handsoff.handtrack.session")
    private nonisolated let videoQueue = DispatchQueue(label: "com.handsoff.handtrack.video")
    private nonisolated let minFrameInterval = 1.0 / 30.0
    // Front camera is mirrored, like the head-track fold-in.
    private nonisolated let visionOrientation: CGImagePropertyOrientation = .upMirrored
    private nonisolated let numHands: Int
    private nonisolated let stateLock = NSLock()
    private nonisolated(unsafe) var session: AVCaptureSession?
    private nonisolated(unsafe) var wantsRunning = false
    private nonisolated(unsafe) var running = false
    private nonisolated(unsafe) var lastFrameTime = 0.0
    // The pixel buffer the in-flight `detectForVideo` reads; set immediately before `process`,
    // both on the video queue, so the LandmarkDetector seam carries no pixels.
    private nonisolated(unsafe) var currentPixelBuffer: CVPixelBuffer?
    private nonisolated(unsafe) lazy var processor = LandmarkProcessor(
        detector: self,
        onResult: { [weak self] result in self?.continuation.yield(result) }
    )

    nonisolated init(numHands: Int = 2) {
        self.numHands = numHands
        (events, continuation) = AsyncStream<DetectionResult>.makeStream()
        super.init()
    }

    // MARK: Control surface

    nonisolated func start() {
        guard requestStart() else { return }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            startAuthorized()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                guard let self else { return }
                if granted { self.startAuthorized() } else { self.clearState() }
            }
        case .denied, .restricted:
            clearState()
        @unknown default:
            clearState()
        }
    }

    nonisolated func stop() {
        guard requestStop() else { return }
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.session?.stopRunning()
            self.session = nil
        }
    }

    /// Stop the feed permanently (host teardown). After this the stream finishes.
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
                self.session = session
                session.startRunning()
            } catch {
                self.clearState()
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
            throw HandLandmarkerError.runtime("No front wide-angle camera found")
        }
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else {
            throw HandLandmarkerError.runtime("Cannot add front camera input")
        }
        session.addInput(input)

        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: videoQueue)
        guard session.canAddOutput(output) else {
            throw HandLandmarkerError.runtime("Cannot add camera video output")
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

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        currentPixelBuffer = pixelBuffer
        // currentTime advances every frame (no skip); nowMs is the capture timestamp the parser
        // stamps and the FPS clock measures. The processor does the dedup/parse/FPS/error gating.
        processor.process(TimedFrameSource(currentTime: now), now * 1000)
    }

    // MARK: LandmarkDetector (runs on the video queue, inside `process`)

    nonisolated func detectForVideo(
        _ source: TimedFrameSource,
        _ timestampMs: Double
    ) throws -> LandmarkParsing.RawHandLandmarkerResult {
        guard let pixelBuffer = currentPixelBuffer else {
            throw HandLandmarkerError.runtime("No pixel buffer for hand detection")
        }
        let request = VNDetectHumanHandPoseRequest()
        request.maximumHandCount = numHands
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: visionOrientation, options: [:])
        try handler.perform([request])

        let observations = (request.results ?? [])
        var landmarks: [[LandmarkParsing.RawLandmark]] = []
        var handednesses: [[LandmarkParsing.RawCategory]] = []
        for observation in observations {
            landmarks.append(Self.rawLandmarks(from: observation))
            handednesses.append([Self.category(from: observation)])
        }
        return LandmarkParsing.RawHandLandmarkerResult(landmarks: landmarks, handednesses: handednesses)
    }

    /// MediaPipe 21-point topology order. Each MediaPipe index maps 1:1 onto a Vision joint:
    /// wrist, then thumb→pinky × (base→tip). Vision's "little" finger is MediaPipe's "pinky".
    private static let topology: [VNHumanHandPoseObservation.JointName] = [
        .wrist,
        .thumbCMC, .thumbMP, .thumbIP, .thumbTip,
        .indexMCP, .indexPIP, .indexDIP, .indexTip,
        .middleMCP, .middlePIP, .middleDIP, .middleTip,
        .ringMCP, .ringPIP, .ringDIP, .ringTip,
        .littleMCP, .littlePIP, .littleDIP, .littleTip,
    ]

    private static func rawLandmarks(from observation: VNHumanHandPoseObservation) -> [LandmarkParsing.RawLandmark] {
        let points = (try? observation.recognizedPoints(.all)) ?? [:]
        return topology.map { joint in
            guard let p = points[joint] else {
                // Vision can omit a low-confidence joint; the contract needs all 21. Emit a
                // zero-visibility placeholder so the pointing ray's occlusion weight falls.
                return LandmarkParsing.RawLandmark(x: 0, y: 0, z: 0, visibility: 0)
            }
            // Vision normalized coords are bottom-left origin (y up); MediaPipe is top-left
            // (y down) — flip y. Vision has no depth for the 2D request, so z = 0; per-joint
            // confidence becomes visibility.
            return LandmarkParsing.RawLandmark(
                x: Double(p.location.x),
                y: 1 - Double(p.location.y),
                z: 0,
                visibility: Double(p.confidence)
            )
        }
    }

    private static func category(from observation: VNHumanHandPoseObservation) -> LandmarkParsing.RawCategory {
        // Vision chirality is image-relative; the front camera is mirrored (`.upMirrored`) so it
        // already matches the MediaPipe-from-image convention. Unknown defaults to "Right".
        let name: String
        switch observation.chirality {
        case .left: name = "Left"
        case .right: name = "Right"
        case .unknown: name = "Right"
        @unknown default: name = "Right"
        }
        return LandmarkParsing.RawCategory(categoryName: name, score: Double(observation.confidence))
    }

    // MARK: Start/stop state (NSLock) — same protocol as HeadPointerService

    private nonisolated func requestStart() -> Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        guard !wantsRunning else { return false }
        wantsRunning = true
        return true
    }

    private nonisolated func requestStop() -> Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        wantsRunning = false
        let hadStarted = running
        running = false
        return hadStarted
    }

    private nonisolated func shouldStartSession() -> Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return wantsRunning
    }

    private nonisolated func beginRunningIfWanted() -> Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        guard wantsRunning else { return false }
        running = true
        return true
    }

    private nonisolated func isRunning() -> Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return running
    }

    private nonisolated func clearState() {
        stateLock.lock()
        wantsRunning = false
        running = false
        stateLock.unlock()
    }
}

enum HandLandmarkerError: LocalizedError {
    case runtime(String)

    var errorDescription: String? {
        switch self {
        case .runtime(let message): return message
        }
    }
}
