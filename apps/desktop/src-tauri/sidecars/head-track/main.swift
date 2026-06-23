import AppKit
import ApplicationServices
import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import IOKit.hid
import QuartzCore
import Vision

private let rightOptionFlagMask: UInt64 = 0x40
private let slashKeyCode: Int64 = 44
private let shiftFlagMask = CGEventFlags.maskShift.rawValue

private struct MappingConfig {
    let yawRange: ClosedRange<Double>
    let pitchRange: ClosedRange<Double>
    let yawSign: Double
    let pitchSign: Double

    static let `default` = MappingConfig(
        yawRange: -0.45...0.45,
        pitchRange: -0.35...0.35,
        yawSign: 1.0,
        pitchSign: 1.0
    )
}

private struct HotkeyState: Equatable {
    var rightOptionHeld = false
    var tracking = false
}

private enum KeyboardEventKind {
    case flagsChanged
    case keyDown
}

private enum HotkeyDecision: Equatable {
    case none
    case start
    case stop
}

private struct HotkeyTapRetryState: Equatable {
    var armed = false
    var retryScheduled = false
}

private enum HotkeyTapRetryAction: Equatable {
    case none
    case armed
    case blocked(scheduleRetry: Bool)
}

private func decideHotkeyTapRetry(
    installed: Bool,
    state: HotkeyTapRetryState
) -> (HotkeyTapRetryState, HotkeyTapRetryAction) {
    guard !state.armed else { return (state, .none) }
    if installed {
        return (HotkeyTapRetryState(armed: true, retryScheduled: false), .armed)
    }
    var next = state
    let shouldSchedule = !next.retryScheduled
    next.retryScheduled = true
    return (next, .blocked(scheduleRetry: shouldSchedule))
}

private struct HotkeyTapPermissionSnapshot {
    let inputMonitoringGranted: Bool
    let accessibilityGranted: Bool
}

private func requestHotkeyTapPermissions() -> HotkeyTapPermissionSnapshot {
    let inputMonitoringGranted = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
    let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
    let accessibilityGranted = AXIsProcessTrustedWithOptions(options)
    return HotkeyTapPermissionSnapshot(
        inputMonitoringGranted: inputMonitoringGranted,
        accessibilityGranted: accessibilityGranted
    )
}

private func currentHotkeyTapPermissions() -> HotkeyTapPermissionSnapshot {
    HotkeyTapPermissionSnapshot(
        inputMonitoringGranted: IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted,
        accessibilityGranted: AXIsProcessTrusted()
    )
}

private func permissionStatus(_ granted: Bool) -> String {
    granted ? "granted" : "pending"
}

private func logHotkeyTapPermissions(_ permissions: HotkeyTapPermissionSnapshot) {
    fputs(
        "head-track: permissions: Input Monitoring \(permissionStatus(permissions.inputMonitoringGranted)), Accessibility \(permissionStatus(permissions.accessibilityGranted))\n",
        stderr
    )
}

private func clamp(_ value: Double, _ range: ClosedRange<Double>) -> Double {
    min(max(value, range.lowerBound), range.upperBound)
}

private func containsInclusive(_ rect: CGRect, _ point: CGPoint) -> Bool {
    point.x >= rect.minX && point.x <= rect.maxX && point.y >= rect.minY && point.y <= rect.maxY
}

private func squaredDistance(_ point: CGPoint, to rect: CGRect) -> Double {
    let x = clamp(point.x, rect.minX...rect.maxX)
    let y = clamp(point.y, rect.minY...rect.maxY)
    let dx = point.x - x
    let dy = point.y - y
    return dx * dx + dy * dy
}

private func clampIntoRealScreen(_ point: CGPoint, screens: [CGRect]) -> CGPoint {
    guard !screens.isEmpty else { return point }
    if screens.contains(where: { containsInclusive($0, point) }) {
        return point
    }
    let nearest = screens.min { squaredDistance(point, to: $0) < squaredDistance(point, to: $1) }!
    return CGPoint(
        x: clamp(point.x, nearest.minX...nearest.maxX),
        y: clamp(point.y, nearest.minY...nearest.maxY)
    )
}

private func mapHeadAnglesToPoint(
    yaw: Double?,
    pitch: Double?,
    screens: [CGRect],
    config: MappingConfig = .default
) -> CGPoint? {
    let union = screens.reduce(nil as CGRect?) { partial, rect in
        guard let partial else { return rect }
        return partial.union(rect)
    }

    guard let union, union.width > 0, union.height > 0 else {
        return nil
    }

    let clampedYaw = clamp((yaw ?? 0) * config.yawSign, config.yawRange)
    let clampedPitch = clamp((pitch ?? 0) * config.pitchSign, config.pitchRange)
    let xRatio = (clampedYaw - config.yawRange.lowerBound) / (config.yawRange.upperBound - config.yawRange.lowerBound)
    let yRatio = (clampedPitch - config.pitchRange.lowerBound) / (config.pitchRange.upperBound - config.pitchRange.lowerBound)
    let point = CGPoint(
        x: union.minX + xRatio * union.width,
        y: union.minY + yRatio * union.height
    )

    return clampIntoRealScreen(point, screens: screens)
}

private func decideHotkey(
    kind: KeyboardEventKind,
    keyCode: Int64,
    flagsRaw: UInt64,
    state: HotkeyState
) -> (HotkeyState, HotkeyDecision) {
    var next = state

    switch kind {
    case .flagsChanged:
        next.rightOptionHeld = (flagsRaw & rightOptionFlagMask) != 0
        if state.tracking && !next.rightOptionHeld {
            next.tracking = false
            return (next, .stop)
        }
        return (next, .none)

    case .keyDown:
        let rightOptionDown = next.rightOptionHeld || (flagsRaw & rightOptionFlagMask) != 0
        let questionMarkDown = keyCode == slashKeyCode && (flagsRaw & shiftFlagMask) != 0
        if rightOptionDown && questionMarkDown && !next.tracking {
            next.rightOptionHeld = true
            next.tracking = true
            return (next, .start)
        }
        return (next, .none)
    }
}

private func epochMillis() -> Int64 {
    Int64((Date().timeIntervalSince1970 * 1000).rounded())
}

private func startEvent(ts: Int64 = epochMillis()) -> [String: Any] {
    ["kind": "start", "ts": ts]
}

private func stopEvent(ts: Int64 = epochMillis()) -> [String: Any] {
    ["kind": "stop", "ts": ts]
}

private func pointEvent(
    x: Double,
    y: Double,
    yaw: Double?,
    pitch: Double?,
    confidence: Double,
    ts: Int64 = epochMillis()
) -> [String: Any] {
    [
        "kind": "point",
        "x": x,
        "y": y,
        "yaw": yaw ?? NSNull(),
        "pitch": pitch ?? NSNull(),
        "confidence": clamp(confidence, 0...1),
        "ts": ts,
    ]
}

private func errorEvent(message: String, ts: Int64 = epochMillis()) -> [String: Any] {
    ["kind": "error", "message": message, "ts": ts]
}

private final class EventWriter {
    private let lock = NSLock()

    func start() {
        emit(startEvent())
    }

    func stop() {
        emit(stopEvent())
    }

    func point(x: Double, y: Double, yaw: Double?, pitch: Double?, confidence: Double) {
        emit(pointEvent(x: x, y: y, yaw: yaw, pitch: pitch, confidence: confidence))
    }

    func error(_ message: String) {
        emit(errorEvent(message: message))
    }

    private func emit(_ object: [String: Any]) {
        lock.lock()
        defer { lock.unlock() }

        do {
            let data = try JSONSerialization.data(withJSONObject: object, options: [])
            if let line = String(data: data, encoding: .utf8) {
                fputs(line, stdout)
                fputc(10, stdout)
                fflush(stdout)
            }
        } catch {
            fputs("head-track: failed to encode stdout event: \(error)\n", stderr)
        }
    }
}

private final class GoldenCursorOverlay {
    private let size: CGFloat = 34
    private lazy var panel: NSPanel = {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: size, height: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .screenSaver
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let view = NSView(frame: NSRect(x: 0, y: 0, width: size, height: size))
        view.wantsLayer = true
        if let layer = view.layer {
            let gold = NSColor(calibratedRed: 1.0, green: 0.73, blue: 0.2, alpha: 1.0).cgColor
            layer.backgroundColor = NSColor(calibratedRed: 1.0, green: 0.83, blue: 0.32, alpha: 0.9).cgColor
            layer.cornerRadius = size / 2
            layer.shadowColor = gold
            layer.shadowOpacity = 0.95
            layer.shadowOffset = .zero
            layer.shadowRadius = 18
            layer.borderColor = NSColor.white.withAlphaComponent(0.8).cgColor
            layer.borderWidth = 1
        }
        panel.contentView = view
        return panel
    }()

    func show(at point: CGPoint) {
        let frame = NSRect(x: point.x - size / 2, y: point.y - size / 2, width: size, height: size)
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
    }
}

private final class HeadTracker: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private let writer: EventWriter
    private let overlay = GoldenCursorOverlay()
    private let sessionQueue = DispatchQueue(label: "com.handsoff.headtrack.session")
    private let videoQueue = DispatchQueue(label: "com.handsoff.headtrack.video")
    private let minFrameInterval = 1.0 / 20.0
    private let visionOrientation: CGImagePropertyOrientation = .upMirrored
    private let stateLock = NSLock()
    private var session: AVCaptureSession?
    private var wantsRunning = false
    private var running = false
    private var lastFrameTime = 0.0

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

    private func startAuthorized() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            guard self.shouldStartSession() else { return }
            do {
                let session = try self.makeSession()
                guard self.beginRunningIfWanted() else { return }
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

        guard let observation = request.results?.first as? VNFaceObservation else {
            return
        }

        let yaw = observation.yaw?.doubleValue
        let pitch = observation.pitch?.doubleValue
        let confidence = Double(observation.confidence)
        let screens = DispatchQueue.main.sync { NSScreen.screens.map(\.frame) }

        guard let point = mapHeadAnglesToPoint(yaw: yaw, pitch: pitch, screens: screens) else {
            writer.error("No screens available for head-point mapping")
            return
        }

        DispatchQueue.main.async { [overlay] in overlay.show(at: point) }
        writer.point(x: point.x, y: point.y, yaw: yaw, pitch: pitch, confidence: confidence)
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

private enum SidecarError: LocalizedError {
    case runtime(String)

    var errorDescription: String? {
        switch self {
        case .runtime(let message): return message
        }
    }
}



private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    let passed = condition()
    assert(passed, message)
    if !passed {
        fatalError(message)
    }
}

private func expectEvent(_ event: [String: Any], kind: String, keys: Set<String>) {
    expect(Set(event.keys) == keys, "\(kind) event has exact wire fields")
    expect(event["kind"] as? String == kind, "\(kind) event kind is stable")
    expect(JSONSerialization.isValidJSONObject(event), "\(kind) event is JSON serializable")
}

private func runSelfTest() {
    let primary = CGRect(x: 0, y: 0, width: 100, height: 100)
    let secondary = CGRect(x: 200, y: 0, width: 100, height: 100)
    let center = mapHeadAnglesToPoint(yaw: 0, pitch: 0, screens: [primary, secondary])!
    expect(containsInclusive(primary, center) || containsInclusive(secondary, center), "gap point clamps into a real screen")

    let left = mapHeadAnglesToPoint(yaw: -0.45, pitch: 0, screens: [primary])!
    let right = mapHeadAnglesToPoint(yaw: 0.45, pitch: 0, screens: [primary])!
    expect(left.x < right.x, "yaw is monotonic left-to-right")

    let low = mapHeadAnglesToPoint(yaw: 0, pitch: -0.35, screens: [primary])!
    let high = mapHeadAnglesToPoint(yaw: 0, pitch: 0.35, screens: [primary])!
    expect(low.y < high.y, "pitch is monotonic bottom-to-top")

    var state = HotkeyState()
    var decision: HotkeyDecision
    (state, decision) = decideHotkey(kind: .flagsChanged, keyCode: 61, flagsRaw: rightOptionFlagMask, state: state)
    expect(decision == .none && state.rightOptionHeld, "right option hold is tracked")
    (state, decision) = decideHotkey(
        kind: .keyDown,
        keyCode: slashKeyCode,
        flagsRaw: rightOptionFlagMask | shiftFlagMask,
        state: state
    )
    expect(decision == .start && state.tracking, "right option plus question mark starts")
    (state, decision) = decideHotkey(kind: .flagsChanged, keyCode: 61, flagsRaw: 0, state: state)
    expect(decision == .stop && !state.tracking, "right option release stops")

    let leftOptionOnly = decideHotkey(kind: .flagsChanged, keyCode: 58, flagsRaw: 0x20, state: HotkeyState())
    expect(leftOptionOnly.1 == .none && !leftOptionOnly.0.rightOptionHeld, "left option does not arm")
    let questionWithoutRightOption = decideHotkey(
        kind: .keyDown,
        keyCode: slashKeyCode,
        flagsRaw: shiftFlagMask,
        state: HotkeyState()
    )
    expect(questionWithoutRightOption.1 == .none, "question mark without right option does not start")

    var retryState = HotkeyTapRetryState()
    var retryAction: HotkeyTapRetryAction
    (retryState, retryAction) = decideHotkeyTapRetry(installed: false, state: retryState)
    expect(retryAction == .blocked(scheduleRetry: true), "blocked tap keeps process alive and schedules retry")
    (retryState, retryAction) = decideHotkeyTapRetry(installed: false, state: retryState)
    expect(retryAction == .blocked(scheduleRetry: false), "repeated blocked tap emits recoverable error without duplicate timer")
    (retryState, retryAction) = decideHotkeyTapRetry(installed: true, state: retryState)
    expect(retryAction == .armed, "later successful tap install arms without relaunch")

    expectEvent(startEvent(ts: 123), kind: "start", keys: ["kind", "ts"])
    expectEvent(stopEvent(ts: 123), kind: "stop", keys: ["kind", "ts"])
    expectEvent(errorEvent(message: "boom", ts: 123), kind: "error", keys: ["kind", "message", "ts"])

    let event = pointEvent(x: 1, y: 2, yaw: nil, pitch: 0.1, confidence: 2, ts: 123)
    expectEvent(event, kind: "point", keys: ["kind", "x", "y", "yaw", "pitch", "confidence", "ts"])
    expect(event["yaw"] is NSNull, "nil yaw serializes as null")
    expect(event["confidence"] as? Double == 1, "confidence is clamped to wire range")

    print("head-track selftest ok")
}

if CommandLine.arguments.contains("--selftest") {
    runSelfTest()
    exit(0)
}

// The capture hotkey (Right Option + ?) is owned by the app process (#95), which
// spawns this sidecar only for the duration of a capture. So tracking auto-starts
// on launch and stops when the host kills the process.
private let writer = EventWriter()
private let tracker = HeadTracker(writer: writer)

NSApplication.shared.setActivationPolicy(.accessory)
tracker.start()
RunLoop.main.run()
