import AppKit
import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import QuartzCore
import Vision

final class HeadTracker: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private let writer: EventWriter
    private let overlay = GoldenCursorOverlay()
    private let sessionQueue = DispatchQueue(label: "com.handsoff.headtrack.session")
    private let videoQueue = DispatchQueue(label: "com.handsoff.headtrack.video")
    private let minFrameInterval = 1.0 / 30.0
    private let visionOrientation: CGImagePropertyOrientation = .upMirrored
    private let stateLock = NSLock()
    private var session: AVCaptureSession?
    private var wantsRunning = false
    private var running = false
    private var lastFrameTime = 0.0
    private var trackingModel = HeadTrackingModel()

    init(writer: EventWriter) {
        self.writer = writer
    }

    func start() {
        guard requestStart() else { return }

        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            startAuthorized()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if granted {
                        self.startAuthorized()
                    } else {
                        self.clearState()
                        self.writer.error("Camera access denied")
                    }
                }
            }
        case .denied, .restricted:
            clearState()
            writer.error("Camera access denied")
        @unknown default:
            clearState()
            writer.error("Unknown camera authorization status")
        }
    }

    func stop() {
        let hadStarted = requestStop()
        DispatchQueue.main.async { [overlay] in overlay.hide() }
        guard hadStarted else { return }
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.session?.stopRunning()
            self.session = nil
            self.writer.stop()
        }
    }

    func applyConfig(_ config: HeadPointerConfig) {
        videoQueue.async { [weak self] in
            self?.trackingModel.applyConfig(config)
        }
    }

    func requestRecenter() {
        videoQueue.async { [weak self] in
            self?.trackingModel.requestRecenter()
        }
    }

    private func startAuthorized() {
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
                self.writer.start()
                session.startRunning()
            } catch {
                self.clearState()
                self.writer.error(error.localizedDescription)
            }
        }
    }

    private func makeSession() throws -> AVCaptureSession {
        let session = AVCaptureSession()
        session.beginConfiguration()
        if session.canSetSessionPreset(.vga640x480) {
            session.sessionPreset = .vga640x480
        }

        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front) else {
            throw SidecarError.runtime("No front wide-angle camera found")
        }
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else {
            throw SidecarError.runtime("Cannot add front camera input")
        }
        session.addInput(input)

        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: videoQueue)
        guard session.canAddOutput(output) else {
            throw SidecarError.runtime("Cannot add camera video output")
        }
        session.addOutput(output)
        session.commitConfiguration()
        return session
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        let now = CACurrentMediaTime()
        guard isRunning(), now - lastFrameTime >= minFrameInterval else { return }
        lastFrameTime = now

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            writer.error("Camera frame missing pixel buffer")
            return
        }

        let request = VNDetectFaceRectanglesRequest()
        request.revision = VNDetectFaceRectanglesRequestRevision3
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: visionOrientation, options: [:])

        do {
            try handler.perform([request])
        } catch {
            writer.error("Vision face detection failed: \(error.localizedDescription)")
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
            writer.error("Vision face landmarks failed: \(error.localizedDescription)")
            return
        }

        guard let landmarkObservation = landmarkRequest.results?.first as? VNFaceObservation,
              let input = landmarkInput(from: landmarkObservation, id: chosen.id),
              let signal = extractSignal(from: input)
        else {
            trackingModel.rejectFrame()
            return
        }

        let screens = DispatchQueue.main.sync { NSScreen.screens.map(\.frame) }

        guard let point = trackingModel.point(for: signal, timestamp: now, screens: screens) else {
            if screens.isEmpty {
                writer.error("No screens available for head-point mapping")
            }
            return
        }

        // The overlay draws in AppKit space (bottom-left); the wire point is
        // flipped to CoreGraphics top-left so it shares cua-driver's window-bounds
        // coordinate space for attention-region ranking (see appKitToGlobalTopLeft).
        DispatchQueue.main.async { [overlay] in overlay.show(at: point) }
        let wirePoint = appKitToGlobalTopLeft(point, screens: screens)
        writer.point(
            x: wirePoint.x, y: wirePoint.y, yaw: signal.yaw, pitch: signal.pitch,
            confidence: signal.confidence)
    }

    private func requestStart() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !wantsRunning else { return false }
        wantsRunning = true
        return true
    }

    private func requestStop() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        wantsRunning = false
        let hadStarted = running
        running = false
        return hadStarted
    }

    private func shouldStartSession() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return wantsRunning
    }

    private func beginRunningIfWanted() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard wantsRunning else { return false }
        running = true
        return true
    }

    private func isRunning() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return running
    }

    private func clearState() {
        stateLock.lock()
        wantsRunning = false
        running = false
        stateLock.unlock()
    }
}

enum SidecarError: LocalizedError {
    case runtime(String)

    var errorDescription: String? {
        switch self {
        case .runtime(let message): return message
        }
    }
}

func startControlReader(tracker: HeadTracker, writer: EventWriter) {
    DispatchQueue.global(qos: .utility).async {
        while let line = readLine(strippingNewline: true) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            guard let command = parseControlCommand(trimmed) else {
                writer.error("Invalid head-track control command")
                continue
            }

            switch command {
            case .config(let config):
                tracker.applyConfig(config)
            case .recenter:
                tracker.requestRecenter()
            }
        }
    }
}
