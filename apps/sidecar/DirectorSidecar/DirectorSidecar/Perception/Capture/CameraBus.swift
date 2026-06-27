import AVFoundation
import CoreMedia
import CoreVideo
import os
import QuartzCore

// AVFoundation timestamped frame bus (SL-0 input path). Capture runs OFF the main thread
// (videoQueue). The session is configured to the highest-frame-rate native-420 format the
// device offers (FR-3). Every frame is emitted as a `FrameSample` carrying the host-clock
// capture timestamp and the Vision-ready CVPixelBuffer — NEVER the CMSampleBuffer (NFR-3).
//
// The *decisions* (which format to pick) are extracted into pure types — `FormatInfo` and
// `CameraFormatSelector` — so they unit-test headless; the AVFoundation session wiring
// below is exercised only at the on-Mac Gate-0 harness.

// MARK: - Format selection (pure, unit-tested headless)

/// The testable slice of an `AVCaptureDevice.Format`: just what format selection needs.
/// Built from a real format at the AVFoundation boundary (`max` of
/// `videoSupportedFrameRateRanges`, the format's media subtype as a pixel format, and the
/// `CMVideoDimensions`), or constructed directly from synthetic values in tests.
public struct FormatInfo: Equatable {
    /// Highest sustainable frame rate (max over `videoSupportedFrameRateRanges`).
    public let maxFrameRate: Double
    /// The format's pixel format (`CMFormatDescription` media subtype as a FourCC).
    public let pixelFormat: OSType
    /// Encoded width in pixels.
    public let width: Int
    /// Encoded height in pixels.
    public let height: Int

    public init(maxFrameRate: Double, pixelFormat: OSType, width: Int, height: Int) {
        self.maxFrameRate = maxFrameRate
        self.pixelFormat = pixelFormat
        self.width = width
        self.height = height
    }

    /// True for the native biplanar 4:2:0 formats (420v video-range / 420f full-range),
    /// which Vision prefers over 32BGRA and which avoid a colorspace conversion.
    public var isNative420: Bool {
        pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            || pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
    }
}

/// Picks the capture format for the Signal lock. Pure — no AVFoundation, no device.
public enum CameraFormatSelector {

    /// Choose the format with the **highest max frame rate**. Tie-break, in order:
    ///   1. higher `maxFrameRate`;
    ///   2. prefer native 420 (420v/420f) over 32BGRA — avoids a colorspace conversion;
    ///   3. among native-420 ties, prefer **420v** (video-range) over 420f (deterministic);
    ///   4. finally larger dimensions (more pixels for Vision).
    /// Returns `nil` for an empty list.
    public static func selectHighestFrameRate(from formats: [FormatInfo]) -> FormatInfo? {
        formats.max { a, b in
            // `max` keeps the element for which the comparator returns false on the pair
            // (a < b); we encode "b is strictly better than a" so the best bubbles up.
            if a.maxFrameRate != b.maxFrameRate { return a.maxFrameRate < b.maxFrameRate }
            if a.isNative420 != b.isNative420 { return !a.isNative420 && b.isNative420 }
            // Prefer 420v over 420f deterministically (only meaningful when both native).
            let aV = a.pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            let bV = b.pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            if aV != bV { return !aV && bV }
            return (a.width * a.height) < (b.width * b.height)
        }
    }
}

// MARK: - Device selection (pure, unit-tested headless)

/// The testable slice of an `AVCaptureDevice`: just what device selection needs. Built from a
/// real device at the AVFoundation boundary (its `uniqueID`, `localizedName`, the `max` over
/// every format's `videoSupportedFrameRateRanges`, and whether its `deviceType` is the
/// built-in wide-angle camera), or constructed directly from synthetic values in tests.
public struct DeviceInfo: Equatable {
    /// Stable identity used to resolve back to the live `AVCaptureDevice` after selection.
    public let uniqueID: String
    /// Human-readable device name (surfaced in the HUD status banner).
    public let name: String
    /// Highest sustainable frame rate across all of the device's formats.
    public let maxFrameRate: Double
    /// True for the Mac's built-in wide-angle camera (FaceTime HD) — preferred on ties.
    public let isBuiltIn: Bool

    public init(uniqueID: String, name: String, maxFrameRate: Double, isBuiltIn: Bool) {
        self.uniqueID = uniqueID
        self.name = name
        self.maxFrameRate = maxFrameRate
        self.isBuiltIn = isBuiltIn
    }
}

/// Picks the capture *device* for the Signal lock. Pure — no AVFoundation, no device.
public enum CameraDeviceSelector {

    /// Choose the device with the **highest max frame rate**. Tie-break, in order:
    ///   1. higher `maxFrameRate` (the whole point — a 60 fps iPhone halves the frame cost);
    ///   2. on equal frame rates, prefer the **built-in** camera for stability (no
    ///      Continuity-Camera wakeup races, no cable/wifi dropouts).
    /// Returns `nil` for an empty list.
    public static func selectHighestFrameRate(from devices: [DeviceInfo]) -> DeviceInfo? {
        devices.max { a, b in
            // `max` keeps the element for which the comparator returns false on the pair
            // (a < b); we encode "b is strictly better than a" so the best bubbles up.
            if a.maxFrameRate != b.maxFrameRate { return a.maxFrameRate < b.maxFrameRate }
            // Equal fps: a built-in is strictly better than a non-built-in.
            if a.isBuiltIn != b.isBuiltIn { return !a.isBuiltIn && b.isBuiltIn }
            return false
        }
    }

    /// Choose the **built-in** camera (the laptop's own) when present — the DEFAULT, so the lab
    /// never grabs a Continuity-Camera iPhone / external webcam unless explicitly asked. On ties
    /// among built-ins, the higher frame rate wins. Falls back to the highest-fps device only when
    /// there is NO built-in. Returns `nil` for an empty list.
    public static func selectBuiltInPreferred(from devices: [DeviceInfo]) -> DeviceInfo? {
        let builtIns = devices.filter(\.isBuiltIn)
        if !builtIns.isEmpty { return selectHighestFrameRate(from: builtIns) }
        return selectHighestFrameRate(from: devices)
    }
}

/// Build a `FrameSample` from a `CVPixelBuffer` and a capture timestamp. This is the ONLY
/// constructor the capture delegate uses: the `CMSampleBuffer` is never passed in, so by
/// construction it cannot escape into a `FrameSample` (NFR-3). Free function so it is
/// directly unit-testable headless.
public func makeFrameSample(pixelBuffer: CVPixelBuffer, tCapture: Double) -> FrameSample {
    FrameSample(tCapture: tCapture, pixelBuffer: pixelBuffer)
}

// MARK: - AVFoundation shell (exercised at the on-Mac Gate-0 harness, not unit-tested)

final class CameraBus: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()
    private let videoQueue = DispatchQueue(label: "com.handsoff.lab.camera.video")
    private let log = Logger(subsystem: "com.handsoff.lab", category: "camera")

    // Reported on the video queue: one FrameSample per captured frame.
    var onFrame: ((FrameSample) -> Void)?
    // Reported on the main thread once the preview layer exists.
    var onPreviewReady: ((AVCaptureVideoPreviewLayer) -> Void)?
    // Reported on the main thread with a human-readable status (HUD banner).
    var onStatus: ((String) -> Void)?
    // Reported on the main thread with the device's selected-format fps ceiling — the
    // HARDWARE capability, not the measured FPS. Surfaced in the HUD so we never imply 60
    // when the chosen format only supports 30 (Fix 3 / RESEARCH.md Q2).
    var onCapability: ((Double) -> Void)?

    /// Whether sensing is currently desired (set on `start`, cleared on `stop`). Touched ONLY on
    /// `videoQueue`, so a late `requestAccess` grant that lands after `stop` is ignored rather than
    /// starting the session behind sensing's back.
    private var sensingDesired = false
    /// The session is configured (inputs/outputs added) exactly once; later start/stop toggles only
    /// flip running, so repeated `setSensing` never re-adds inputs or accumulates duplicate outputs.
    private var isConfigured = false

    /// Bring the camera up. All session mutation is serialized onto `videoQueue` (incl. the async
    /// permission callback), so configuration, `startRunning`, and `stopRunning` never race.
    func start() {
        videoQueue.async { [weak self] in self?.startOnQueue() }
    }

    /// Always on `videoQueue`.
    private func startOnQueue() {
        sensingDesired = true
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureAndRun()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                guard let self else { return }
                self.videoQueue.async {
                    guard granted, self.sensingDesired else {
                        if !granted { self.emitStatus("camera DENIED — grant Camera permission to the app/Terminal") }
                        return  // denied, or sensing was turned off while we waited — don't start
                    }
                    self.configureAndRun()
                }
            }
        case .denied, .restricted:
            emitStatus("camera DENIED — grant Camera permission to the app/Terminal")
        @unknown default:
            emitStatus("camera authorization unknown")
        }
    }

    /// Stop the capture session (idempotent). Serialized on `videoQueue` with `start`, and clears
    /// `sensingDesired` so an in-flight permission grant can't start the session after this returns.
    func stop() {
        videoQueue.async { [weak self] in
            guard let self else { return }
            self.sensingDesired = false
            if self.session.isRunning { self.session.stopRunning() }
        }
    }

    /// Always on `videoQueue`. Configures the session ONCE; subsequent calls only resume running.
    private func configureAndRun() {
        guard sensingDesired else { return }
        if isConfigured {
            if !session.isRunning { session.startRunning() }
            return
        }
        session.beginConfiguration()

        // Discover EVERY candidate camera (the built-in FaceTime HD caps at 30 fps; a
        // Continuity-Camera iPhone or external webcam can offer 60 fps and halve the
        // frame-bound latency). The hardcoded built-in lookup never saw the 60-fps device.
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera, .deskViewCamera],
            mediaType: .video,
            position: .unspecified
        )
        let devices = discovery.devices
        guard !devices.isEmpty else {
            session.commitConfiguration()
            emitStatus("no camera available")
            return
        }

        // Map each live device to the pure DeviceInfo the selector consumes, logging every
        // candidate with its fps ceiling so a 30-fps-only setup is visible at startup.
        let deviceInfos = devices.map { Self.deviceInfo(from: $0) }
        log.info("camera devices (\(deviceInfos.count, privacy: .public) discovered):")
        for info in deviceInfos {
            log.info("  dev \"\(info.name, privacy: .public)\" maxFPS=\(info.maxFrameRate, privacy: .public)\(info.isBuiltIn ? " [builtin]" : "", privacy: .public)")
        }

        // Pick the device:
        //   1. an explicit HANDSOFF_CAMERA substring (case-insensitive) override wins if it matches
        //      a discovered device's localizedName (use this to force the iPhone or a webcam);
        //   2. otherwise the BUILT-IN laptop camera by default (no Continuity-Camera iPhone / webcam
        //      wakeup races or dropouts) — set HANDSOFF_CAMERA_HIGHEST_FPS=1 to instead pick the
        //      highest-fps device (e.g. a 60 fps iPhone) for the latency-optimized path.
        let wantHighestFps = ProcessInfo.processInfo.environment["HANDSOFF_CAMERA_HIGHEST_FPS"] == "1"
        let pickInfo = wantHighestFps
            ? CameraDeviceSelector.selectHighestFrameRate(from: deviceInfos)
            : CameraDeviceSelector.selectBuiltInPreferred(from: deviceInfos)
        let chosenDevice: AVCaptureDevice
        if let override = ProcessInfo.processInfo.environment["HANDSOFF_CAMERA"],
           !override.isEmpty,
           let match = devices.first(where: {
               $0.localizedName.range(of: override, options: .caseInsensitive) != nil
           }) {
            chosenDevice = match
            log.info("camera override HANDSOFF_CAMERA=\"\(override, privacy: .public)\" → \"\(match.localizedName, privacy: .public)\"")
        } else if let pick = pickInfo,
                  let match = devices.first(where: { $0.uniqueID == pick.uniqueID }) {
            chosenDevice = match
        } else {
            // Selector returned nil only on an empty list (already guarded); defensive fallback.
            chosenDevice = devices[0]
        }

        let device = chosenDevice
        log.info("camera device chosen: \"\(device.localizedName, privacy: .public)\"")

        guard let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            session.commitConfiguration()
            emitStatus("camera \"\(device.localizedName)\" cannot be opened")
            return
        }
        session.addInput(input)

        // Pick the highest-frame-rate native-420 format via the pure selector, then pin
        // the device's active format + min/max frame duration to that fps.
        let infos = device.formats.map { Self.formatInfo(from: $0) }

        // Fix 3: log EVERY enumerated format (max fps, pixel format, dimensions) and which
        // one we selected, so we can see at startup whether 60 fps is even on offer for a
        // native-420 format — the device's true ceiling (RESEARCH.md Q2). targetFPS=60 is a
        // request, not a guarantee; the first on-Mac run showed 30 despite asking for 60.
        log.info("camera formats (\(infos.count, privacy: .public) enumerated):")
        for info in infos {
            log.info("  fmt \(Self.fourCCString(info.pixelFormat), privacy: .public) \(info.width, privacy: .public)x\(info.height, privacy: .public) maxFPS=\(info.maxFrameRate, privacy: .public)\(info.isNative420 ? " [native420]" : "", privacy: .public)")
        }

        var capabilityFPS = 0.0
        if let chosen = CameraFormatSelector.selectHighestFrameRate(from: infos),
           let match = device.formats.first(where: { Self.formatInfo(from: $0) == chosen }),
           (try? device.lockForConfiguration()) != nil {
            device.activeFormat = match
            // The hardware ceiling of the CHOSEN format (device-reported), independent of
            // the targetFPS request and of the measured FPS.
            capabilityFPS = chosen.maxFrameRate
            log.info("camera selected: \(Self.fourCCString(chosen.pixelFormat), privacy: .public) \(chosen.width, privacy: .public)x\(chosen.height, privacy: .public) maxFPS=\(chosen.maxFrameRate, privacy: .public) (targetFPS request=\(Params.capture.targetFPS, privacy: .public))")
            // Clamp to the chosen fps (don't exceed the target FPS knob).
            let fps = min(chosen.maxFrameRate, Double(Params.capture.targetFPS))
            if fps > 0 {
                let duration = CMTime(value: 1, timescale: CMTimeScale(fps.rounded()))
                device.activeVideoMinFrameDuration = duration
                device.activeVideoMaxFrameDuration = duration
            }
            device.unlockForConfiguration()
        }
        DispatchQueue.main.async { [weak self] in self?.onCapability?(capabilityFPS) }

        let output = AVCaptureVideoDataOutput()
        // Request native 420v (falls back gracefully if the device negotiates otherwise).
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        ]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: videoQueue)
        if session.canAddOutput(output) { session.addOutput(output) }
        session.commitConfiguration()

        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        // Mirror the PREVIEW so it reads like a mirror (move right → your image moves right),
        // matching the selfie convention the pointer uses (`Params.capture.mirrorX`). This is a
        // DISPLAY-only flip on the preview connection — it does NOT touch the data-output pixel
        // buffers fed to Vision, so the pointer/calibration math is unaffected.
        if let conn = preview.connection, conn.isVideoMirroringSupported {
            conn.automaticallyAdjustsVideoMirroring = false
            conn.isVideoMirrored = Params.capture.mirrorX
        }
        let deviceName = device.localizedName
        DispatchQueue.main.async { [weak self] in
            self?.onPreviewReady?(preview)
            // Surface the CHOSEN device name in the HUD banner, e.g. "(iPhone … running)",
            // so it's obvious at a glance which camera is feeding the lock.
            self?.emitStatus("\(deviceName) running")
        }
        isConfigured = true
        if sensingDesired { session.startRunning() }  // already on videoQueue
    }

    /// Render an `OSType` FourCC (e.g. `420v`) as a printable string for logging.
    private static func fourCCString(_ code: OSType) -> String {
        let bytes = [
            UInt8((code >> 24) & 0xFF),
            UInt8((code >> 16) & 0xFF),
            UInt8((code >> 8) & 0xFF),
            UInt8(code & 0xFF),
        ]
        let scalars = bytes.map { (0x20...0x7E).contains($0) ? Character(UnicodeScalar($0)) : "?" }
        return String(scalars)
    }

    /// Map a live `AVCaptureDevice.Format` to the pure `FormatInfo` the selector consumes.
    private static func formatInfo(from format: AVCaptureDevice.Format) -> FormatInfo {
        let maxFR = format.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0
        let subType = CMFormatDescriptionGetMediaSubType(format.formatDescription)
        let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        return FormatInfo(
            maxFrameRate: maxFR,
            pixelFormat: subType,
            width: Int(dims.width),
            height: Int(dims.height)
        )
    }

    /// Map a live `AVCaptureDevice` to the pure `DeviceInfo` the device selector consumes.
    /// `maxFrameRate` is the max over every format's `videoSupportedFrameRateRanges`;
    /// `isBuiltIn` is true only for the Mac's built-in wide-angle (FaceTime HD) camera.
    private static func deviceInfo(from device: AVCaptureDevice) -> DeviceInfo {
        let maxFR = device.formats
            .flatMap { $0.videoSupportedFrameRateRanges }
            .map(\.maxFrameRate)
            .max() ?? 0
        return DeviceInfo(
            uniqueID: device.uniqueID,
            name: device.localizedName,
            maxFrameRate: maxFR,
            isBuiltIn: device.deviceType == .builtInWideAngleCamera
        )
    }

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        // NFR-3: the CMSampleBuffer NEVER escapes this scope. We extract ONLY two scalars
        // from it — the presentation timestamp (PTS) and the CVPixelBuffer
        // (CMSampleBufferGetImageBuffer); the FrameSample is built from that buffer + the
        // PTS scalar via makeFrameSample. The sampleBuffer parameter itself is not stored,
        // captured, or forwarded anywhere.
        //
        // tCapture comes from the sample buffer's PTS, NOT from frame-delivery time. The PTS
        // is on the host-time clock (CMClockGetHostTimeClock — the same base as
        // CACurrentMediaTime), so it stays directly comparable with the render-commit
        // tPhoton stamped in OverlayPanel. Reading delivery time here would discard the
        // capture-pipeline latency (the dominant webcam cost) and make it invisible.
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let tCapture = pts.isValid ? pts.seconds : CACurrentMediaTime()
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let sample = makeFrameSample(pixelBuffer: pixelBuffer, tCapture: tCapture)
        onFrame?(sample)
    }

    private func emitStatus(_ s: String) {
        DispatchQueue.main.async { [weak self] in self?.onStatus?(s) }
    }
}
