import AppKit
import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import QuartzCore
import Vision

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

private enum MovementMode: String {
    case edge
    case relative
}

private struct HeadPointerConfig: Equatable {
    var movementMode: MovementMode
    var speed: Double
    var distanceToEdge: Double

    static let `default` = HeadPointerConfig(movementMode: .edge, speed: 5, distanceToEdge: 0.12)

    var sanitized: HeadPointerConfig {
        HeadPointerConfig(
            movementMode: movementMode,
            speed: clamp(speed, 1...10),
            distanceToEdge: clamp(distanceToEdge, 0.02...0.4)
        )
    }
}

private enum ControlCommand: Equatable {
    case config(HeadPointerConfig)
    case recenter
}

private func doubleValue(_ value: Any?) -> Double? {
    if let value = value as? NSNumber {
        return value.doubleValue
    }
    if let value = value as? Double {
        return value
    }
    if let value = value as? String {
        return Double(value)
    }
    return nil
}

private func parseControlCommand(_ line: String) -> ControlCommand? {
    guard let data = line.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let kind = object["kind"] as? String
    else {
        return nil
    }

    switch kind {
    case "recenter":
        return .recenter
    case "config":
        guard let headPointer = object["headPointer"] as? [String: Any] else { return nil }
        let modeRaw = headPointer["movementMode"] as? String ?? MovementMode.edge.rawValue
        guard let mode = MovementMode(rawValue: modeRaw) else { return nil }
        let config = HeadPointerConfig(
            movementMode: mode,
            speed: doubleValue(headPointer["speed"]) ?? HeadPointerConfig.default.speed,
            distanceToEdge: doubleValue(headPointer["distanceToEdge"]) ?? HeadPointerConfig.default.distanceToEdge
        )
        return .config(config.sanitized)
    default:
        return nil
    }
}

private func unionRect(_ screens: [CGRect]) -> CGRect? {
    screens.reduce(nil as CGRect?) { partial, rect in
        guard let partial else { return rect }
        return partial.union(rect)
    }
}

private func defaultPointerPoint(screens: [CGRect]) -> CGPoint? {
    guard let union = unionRect(screens), union.width > 0, union.height > 0 else {
        return nil
    }
    return clampIntoRealScreen(CGPoint(x: union.midX, y: union.midY), screens: screens)
}

private func center(_ rect: CGRect) -> CGPoint {
    CGPoint(x: rect.midX, y: rect.midY)
}

private func distance(_ a: CGPoint, _ b: CGPoint) -> Double {
    let dx = a.x - b.x
    let dy = a.y - b.y
    return sqrt(dx * dx + dy * dy)
}

private func blend(_ a: CGPoint, _ b: CGPoint, alpha: Double) -> CGPoint {
    CGPoint(x: a.x + (b.x - a.x) * alpha, y: a.y + (b.y - a.y) * alpha)
}

private func area(_ rect: CGRect) -> Double {
    max(0, rect.width) * max(0, rect.height)
}

private func intersectionOverUnion(_ a: CGRect, _ b: CGRect) -> Double {
    let intersection = a.intersection(b)
    let union = area(a) + area(b) - area(intersection)
    guard union > 0 else { return 0 }
    return area(intersection) / union
}

private struct FaceCandidate {
    let id: String
    let boundingBox: CGRect
    let confidence: Double
    let observation: VNFaceObservation?

    init(id: String, boundingBox: CGRect, confidence: Double, observation: VNFaceObservation? = nil) {
        self.id = id
        self.boundingBox = boundingBox
        self.confidence = confidence
        self.observation = observation
    }
}

private struct ActiveFaceTracker {
    private let minConfidence = 0.45
    private let lostFrameLimit = 3
    private let switchConfidenceMargin = 0.22
    private let currentAffinityThreshold = 0.2
    private var active: FaceCandidate?
    private var lastAcceptedBox: CGRect?
    private var boxVelocity = CGPoint.zero
    private var lostFrames = 0
    private var freshTrack = false

    var predictedBox: CGRect? {
        guard !freshTrack else { return nil }
        let box = lastAcceptedBox ?? active?.boundingBox
        return box?.offsetBy(dx: boxVelocity.x, dy: boxVelocity.y)
    }

    var needsFreshSignal: Bool {
        freshTrack
    }

    mutating func reset() {
        active = nil
        lastAcceptedBox = nil
        boxVelocity = .zero
        lostFrames = 0
        freshTrack = false
    }

    mutating func choose(from faces: [FaceCandidate]) -> FaceCandidate? {
        let validFaces = faces.filter { $0.confidence >= minConfidence }
        guard !validFaces.isEmpty else {
            return markMissing()
        }

        guard let active else {
            return setActive(bestCandidate(in: validFaces))
        }

        let predicted = predictedBox ?? active.boundingBox
        let currentMatch = validFaces.max { affinity($0, to: predicted) < affinity($1, to: predicted) }
        let currentAffinity = currentMatch.map { affinity($0, to: predicted) } ?? 0
        let best = bestCandidate(in: validFaces)

        guard let currentMatch, currentAffinity >= currentAffinityThreshold else {
            lostFrames += 1
            if lostFrames >= lostFrameLimit {
                return replaceActive(with: best)
            }
            return nil
        }

        if best.id != currentMatch.id,
           best.confidence >= currentMatch.confidence + switchConfidenceMargin {
            return replaceActive(with: best)
        }

        return setActive(currentMatch)
    }

    mutating func accept(_ signal: HeadSignal) {
        if freshTrack {
            boxVelocity = .zero
            freshTrack = false
        } else if let lastAcceptedBox {
            boxVelocity = CGPoint(
                x: signal.faceBox.midX - lastAcceptedBox.midX,
                y: signal.faceBox.midY - lastAcceptedBox.midY
            )
        }
        lastAcceptedBox = signal.faceBox
        lostFrames = 0
    }

    mutating func rejectFrame() {
        lostFrames += 1
        if lostFrames >= lostFrameLimit {
            active = nil
            lastAcceptedBox = nil
            boxVelocity = .zero
            freshTrack = true
        }
    }

    private mutating func markMissing() -> FaceCandidate? {
        guard active != nil else { return nil }
        lostFrames += 1
        if lostFrames >= lostFrameLimit {
            active = nil
            lastAcceptedBox = nil
            boxVelocity = .zero
            freshTrack = true
        }
        return nil
    }

    private mutating func setActive(_ candidate: FaceCandidate) -> FaceCandidate {
        active = candidate
        lostFrames = 0
        return candidate
    }

    private mutating func replaceActive(with candidate: FaceCandidate) -> FaceCandidate {
        active = candidate
        lastAcceptedBox = nil
        boxVelocity = .zero
        lostFrames = 0
        freshTrack = true
        return candidate
    }

    private func bestCandidate(in faces: [FaceCandidate]) -> FaceCandidate {
        faces.max { $0.confidence < $1.confidence }!
    }

    private func affinity(_ candidate: FaceCandidate, to box: CGRect) -> Double {
        let iou = intersectionOverUnion(candidate.boundingBox, box)
        let centerDistance = distance(center(candidate.boundingBox), center(box))
        let scale = abs(sqrt(area(candidate.boundingBox)) - sqrt(area(box)))
        return iou * 1.4 - centerDistance * 1.1 - scale * 0.5
    }
}

private struct LandmarkInput {
    let face: FaceCandidate
    let leftEye: [CGPoint]?
    let rightEye: [CGPoint]?
    let nose: [CGPoint]?
    let yaw: Double?
    let pitch: Double?
}

private struct HeadSignal {
    let faceBox: CGRect
    let faceCenter: CGPoint
    let eyeMidpoint: CGPoint
    let eyeDistance: Double
    let noseOffset: CGPoint
    let roll: Double
    let yaw: Double?
    let pitch: Double?
    let confidence: Double

    init(
        faceBox: CGRect,
        faceCenter: CGPoint,
        eyeMidpoint: CGPoint,
        eyeDistance: Double,
        noseOffset: CGPoint,
        roll: Double,
        yaw: Double?,
        pitch: Double?,
        confidence: Double
    ) {
        self.faceBox = faceBox
        self.faceCenter = faceCenter
        self.eyeMidpoint = eyeMidpoint
        self.eyeDistance = eyeDistance
        self.noseOffset = noseOffset
        self.roll = roll
        self.yaw = yaw
        self.pitch = pitch
        self.confidence = confidence
    }

    init(_ signal: HeadSignal, faceBox: CGRect? = nil, eyeDistance: Double? = nil, confidence: Double? = nil) {
        self.faceBox = faceBox ?? signal.faceBox
        self.faceCenter = faceBox.map(center) ?? signal.faceCenter
        self.eyeMidpoint = signal.eyeMidpoint
        self.eyeDistance = eyeDistance ?? signal.eyeDistance
        self.noseOffset = signal.noseOffset
        self.roll = signal.roll
        self.yaw = signal.yaw
        self.pitch = signal.pitch
        self.confidence = confidence ?? signal.confidence
    }

    func blended(with raw: HeadSignal, alpha: Double) -> HeadSignal {
        HeadSignal(
            faceBox: CGRect(
                x: faceBox.origin.x + (raw.faceBox.origin.x - faceBox.origin.x) * alpha,
                y: faceBox.origin.y + (raw.faceBox.origin.y - faceBox.origin.y) * alpha,
                width: faceBox.width + (raw.faceBox.width - faceBox.width) * alpha,
                height: faceBox.height + (raw.faceBox.height - faceBox.height) * alpha
            ),
            faceCenter: blend(faceCenter, raw.faceCenter, alpha: alpha),
            eyeMidpoint: blend(eyeMidpoint, raw.eyeMidpoint, alpha: alpha),
            eyeDistance: eyeDistance + (raw.eyeDistance - eyeDistance) * alpha,
            noseOffset: blend(noseOffset, raw.noseOffset, alpha: alpha),
            roll: roll + (raw.roll - roll) * alpha,
            yaw: blendOptional(yaw, raw.yaw, alpha: alpha),
            pitch: blendOptional(pitch, raw.pitch, alpha: alpha),
            confidence: raw.confidence
        )
    }
}

private func blendOptional(_ previous: Double?, _ raw: Double?, alpha: Double) -> Double? {
    guard let raw else { return previous }
    guard let previous else { return raw }
    return previous + (raw - previous) * alpha
}

private func centroid(_ points: [CGPoint]?) -> CGPoint? {
    guard let points, !points.isEmpty else { return nil }
    let sum = points.reduce(CGPoint.zero) { partial, point in
        CGPoint(x: partial.x + point.x, y: partial.y + point.y)
    }
    return CGPoint(x: sum.x / Double(points.count), y: sum.y / Double(points.count))
}

private func extractSignal(from input: LandmarkInput) -> HeadSignal? {
    guard let leftEye = centroid(input.leftEye),
          let rightEye = centroid(input.rightEye),
          let nose = centroid(input.nose)
    else {
        return nil
    }

    let eyeDistance = distance(leftEye, rightEye)
    guard eyeDistance >= 0.03 else { return nil }

    let eyeMidpoint = CGPoint(x: (leftEye.x + rightEye.x) / 2, y: (leftEye.y + rightEye.y) / 2)
    let noseOffset = CGPoint(
        x: (nose.x - eyeMidpoint.x) / eyeDistance,
        y: (nose.y - eyeMidpoint.y) / eyeDistance
    )

    return HeadSignal(
        faceBox: input.face.boundingBox,
        faceCenter: center(input.face.boundingBox),
        eyeMidpoint: eyeMidpoint,
        eyeDistance: eyeDistance,
        noseOffset: noseOffset,
        roll: atan2(rightEye.y - leftEye.y, rightEye.x - leftEye.x),
        yaw: input.yaw,
        pitch: input.pitch,
        confidence: input.face.confidence
    )
}

private struct FrameGate {
    private let minConfidence = 0.45
    private let maxCenterJump = 0.28
    private let maxScaleRatio = 1.7
    private let minScaleRatio = 0.58

    func accepts(_ signal: HeadSignal, previous: HeadSignal?, predictedBox: CGRect?) -> Bool {
        guard signal.confidence >= minConfidence, signal.eyeDistance >= 0.03 else {
            return false
        }

        if let predictedBox,
           distance(center(signal.faceBox), center(predictedBox)) > maxCenterJump {
            return false
        }

        if let previous {
            let ratio = signal.eyeDistance / previous.eyeDistance
            if ratio > maxScaleRatio || ratio < minScaleRatio {
                return false
            }
        }

        return true
    }
}

private struct SignalVector {
    var x: Double
    var y: Double

    static let zero = SignalVector(x: 0, y: 0)

    var magnitude: Double {
        sqrt(x * x + y * y)
    }

    func scaled(_ scalar: Double) -> SignalVector {
        SignalVector(x: x * scalar, y: y * scalar)
    }
}

private func - (lhs: SignalVector, rhs: SignalVector) -> SignalVector {
    SignalVector(x: lhs.x - rhs.x, y: lhs.y - rhs.y)
}

private func + (lhs: SignalVector, rhs: SignalVector) -> SignalVector {
    SignalVector(x: lhs.x + rhs.x, y: lhs.y + rhs.y)
}

private enum TrackingState {
    case acquiring
    case tracking
    case recenterPending
    case lost
}

private struct HeadPointerMotion {
    var config: HeadPointerConfig
    private(set) var state: TrackingState = .acquiring
    private var neutral: HeadSignal?
    private var filtered: HeadSignal?
    private var previousVector = SignalVector.zero
    private var previousTimestamp: Double?
    private var outputPoint: CGPoint?
    private var movementActive = false
    private var stableTime = 0.0
    private var rejectedFrames = 0
    private let rejectionBudget = 3

    var neutralNoseOffsetXForSelfTest: Double? {
        guard let x = neutral?.noseOffset.x else { return nil }
        return Double(x)
    }

    init(config: HeadPointerConfig) {
        self.config = config.sanitized
    }

    mutating func reset() {
        state = .acquiring
        neutral = nil
        filtered = nil
        previousVector = .zero
        previousTimestamp = nil
        outputPoint = nil
        movementActive = false
        stableTime = 0
        rejectedFrames = 0
    }

    mutating func applyConfig(_ next: HeadPointerConfig) {
        config = next.sanitized
    }

    mutating func requestRecenter() {
        state = .recenterPending
    }

    mutating func rejectFrame() -> CGPoint? {
        rejectedFrames += 1
        if rejectedFrames >= rejectionBudget {
            state = .lost
            filtered = nil
            movementActive = false
        }
        return outputPoint
    }

    mutating func step(signal rawSignal: HeadSignal, timestamp: Double, screens: [CGRect]) -> CGPoint? {
        guard var point = outputPoint ?? defaultPointerPoint(screens: screens) else {
            return nil
        }

        let dt = frameDelta(timestamp)
        rejectedFrames = 0

        if neutral == nil || state == .acquiring || state == .lost {
            neutral = rawSignal
            filtered = rawSignal
            previousVector = .zero
            previousTimestamp = timestamp
            outputPoint = point
            state = .tracking
            return point
        }

        if state == .recenterPending {
            neutral = rawSignal
            filtered = rawSignal
            previousVector = .zero
            previousTimestamp = timestamp
            outputPoint = defaultPointerPoint(screens: screens) ?? point
            movementActive = false
            stableTime = 0
            state = .tracking
            return outputPoint
        }

        guard let neutral else { return point }
        let rawVector = controlVector(for: rawSignal, neutral: neutral)
        let alpha = smoothingAlpha(rawVector: rawVector, dt: dt)
        let smoothed = (filtered ?? rawSignal).blended(with: rawSignal, alpha: alpha)
        let smoothedVector = controlVector(for: smoothed, neutral: neutral)
        filtered = smoothed
        previousVector = smoothedVector
        previousTimestamp = timestamp

        let velocity = pointerVelocity(rawVector: rawVector, smoothedVector: smoothedVector)
        point = CGPoint(x: point.x + velocity.x * dt, y: point.y + velocity.y * dt)
        point = clampIntoRealScreen(point, screens: screens)
        outputPoint = point
        updateStableRecenter(rawVector: rawVector, smoothed: smoothed, dt: dt)
        state = .tracking
        return point
    }

    private mutating func frameDelta(_ timestamp: Double) -> Double {
        defer { previousTimestamp = timestamp }
        guard let previousTimestamp, timestamp > previousTimestamp else {
            return 1.0 / 30.0
        }
        return min(max(timestamp - previousTimestamp, 1.0 / 120.0), 0.25)
    }

    private func controlVector(for signal: HeadSignal, neutral: HeadSignal) -> SignalVector {
        let noseX = signal.noseOffset.x - neutral.noseOffset.x
        let noseY = signal.noseOffset.y - neutral.noseOffset.y
        let yaw = (signal.yaw ?? neutral.yaw ?? 0) - (neutral.yaw ?? 0)
        let pitch = (signal.pitch ?? neutral.pitch ?? 0) - (neutral.pitch ?? 0)
        let centerX = signal.faceCenter.x - neutral.faceCenter.x
        let centerY = signal.faceCenter.y - neutral.faceCenter.y

        switch config.movementMode {
        case .edge:
            return SignalVector(
                x: noseX * 0.75 + yaw * 0.55 + centerX * 0.25,
                y: noseY * 0.75 + pitch * 0.55 + centerY * 0.25
            )
        case .relative:
            let scale = max(neutral.faceBox.width, 0.1)
            return SignalVector(
                x: centerX / scale + noseX * 0.25,
                y: centerY / scale + noseY * 0.25
            )
        }
    }

    private func smoothingAlpha(rawVector: SignalVector, dt: Double) -> Double {
        let speed = (rawVector - previousVector).magnitude / max(dt, 0.001)
        return clamp(0.10 + rawVector.magnitude * 0.55 + min(speed * 0.025, 0.28), 0.10...0.52)
    }

    private mutating func pointerVelocity(rawVector: SignalVector, smoothedVector: SignalVector) -> SignalVector {
        let outer = max(config.distanceToEdge, 0.01)
        let inner = outer * 0.55
        let rawMagnitude = rawVector.magnitude

        if movementActive {
            if rawMagnitude < inner {
                movementActive = false
            }
        } else if rawMagnitude > outer {
            movementActive = true
        }

        let driveVector = smoothedVector.magnitude >= inner ? smoothedVector : rawVector
        guard movementActive, driveVector.magnitude > 0 else {
            return .zero
        }

        let excess = max(driveVector.magnitude - inner, 0)
        let normalized = min(excess / max(1 - inner, 0.001), 1)
        let gain = pow(normalized, 1.35)
        let maxPixelsPerSecond = 180 + config.speed * 90
        let scalar = maxPixelsPerSecond * gain / driveVector.magnitude
        return driveVector.scaled(scalar)
    }

    private mutating func updateStableRecenter(rawVector: SignalVector, smoothed: HeadSignal, dt: Double) {
        let inner = max(config.distanceToEdge, 0.01) * 0.55
        guard rawVector.magnitude < inner, movementActive == false else {
            stableTime = 0
            return
        }

        stableTime += dt
        if stableTime >= 2.0, let currentNeutral = neutral {
            neutral = currentNeutral.blended(with: smoothed, alpha: min(dt * 0.02, 0.02))
        }
    }
}

private struct HeadTrackingModel {
    private var faceTracker = ActiveFaceTracker()
    private var motion = HeadPointerMotion(config: .default)
    private let gate = FrameGate()
    private var lastAcceptedSignal: HeadSignal?

    mutating func reset() {
        faceTracker.reset()
        motion.reset()
        lastAcceptedSignal = nil
    }

    mutating func applyConfig(_ config: HeadPointerConfig) {
        motion.applyConfig(config)
    }

    mutating func requestRecenter() {
        motion.requestRecenter()
    }

    mutating func chooseFace(from faces: [FaceCandidate]) -> FaceCandidate? {
        faceTracker.choose(from: faces)
    }

    mutating func rejectFrame() {
        faceTracker.rejectFrame()
        _ = motion.rejectFrame()
        if motion.state == .lost {
            lastAcceptedSignal = nil
        }
    }

    mutating func missFace() {
        _ = motion.rejectFrame()
        if motion.state == .lost {
            lastAcceptedSignal = nil
        }
    }

    mutating func point(for signal: HeadSignal, timestamp: Double, screens: [CGRect]) -> CGPoint? {
        let freshTrack = faceTracker.needsFreshSignal
        guard gate.accepts(
            signal,
            previous: freshTrack ? nil : lastAcceptedSignal,
            predictedBox: faceTracker.predictedBox
        ) else {
            rejectFrame()
            return nil
        }

        faceTracker.accept(signal)
        lastAcceptedSignal = signal
        return motion.step(signal: signal, timestamp: timestamp, screens: screens)
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

private func landmarkPoints(_ region: VNFaceLandmarkRegion2D?, in faceBox: CGRect) -> [CGPoint]? {
    guard let region, region.pointCount > 0 else { return nil }
    return region.normalizedPoints.map { point in
        CGPoint(
            x: faceBox.minX + point.x * faceBox.width,
            y: faceBox.minY + point.y * faceBox.height
        )
    }
}

private func landmarkInput(from observation: VNFaceObservation, id: String) -> LandmarkInput? {
    guard let landmarks = observation.landmarks else { return nil }
    let face = FaceCandidate(
        id: id,
        boundingBox: observation.boundingBox,
        confidence: Double(observation.confidence),
        observation: observation
    )
    return LandmarkInput(
        face: face,
        leftEye: landmarkPoints(landmarks.leftEye, in: observation.boundingBox),
        rightEye: landmarkPoints(landmarks.rightEye, in: observation.boundingBox),
        nose: landmarkPoints(landmarks.nose, in: observation.boundingBox),
        yaw: observation.yaw?.doubleValue,
        pitch: observation.pitch?.doubleValue
    )
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

        DispatchQueue.main.async { [overlay] in overlay.show(at: point) }
        writer.point(x: point.x, y: point.y, yaw: signal.yaw, pitch: signal.pitch, confidence: signal.confidence)
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

private func startControlReader(tracker: HeadTracker, writer: EventWriter) {
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

private func expectClose(_ actual: Double, _ expected: Double, tolerance: Double, _ message: String) {
    expect(abs(actual - expected) <= tolerance, message)
}

private func testActiveFaceSelection() {
    var tracker = ActiveFaceTracker()
    let current = FaceCandidate(id: "current", boundingBox: CGRect(x: 0.1, y: 0.2, width: 0.25, height: 0.35), confidence: 0.72)
    let slightCompetitor = FaceCandidate(id: "competitor", boundingBox: CGRect(x: 0.65, y: 0.2, width: 0.25, height: 0.35), confidence: 0.79)
    let clearCompetitor = FaceCandidate(id: "winner", boundingBox: CGRect(x: 0.65, y: 0.2, width: 0.25, height: 0.35), confidence: 0.98)

    expect(tracker.choose(from: [current])?.id == "current", "one valid face becomes active")
    expect(tracker.choose(from: [slightCompetitor, current])?.id == "current", "active face resists slight confidence wins")
    expect(tracker.choose(from: [slightCompetitor]) == nil, "short active-face dropout holds instead of switching")
    expect(tracker.choose(from: [slightCompetitor]) == nil, "second active-face dropout still holds")
    expect(tracker.choose(from: [slightCompetitor])?.id == "competitor", "lost active face reacquires best candidate")

    tracker = ActiveFaceTracker()
    _ = tracker.choose(from: [current])
    tracker.accept(makeSignal(x: 0))
    expect(tracker.predictedBox != nil, "accepted active face predicts the next box")
    let farReentry = FaceCandidate(id: "far-reentry", boundingBox: CGRect(x: 0.78, y: 0.2, width: 0.18, height: 0.3), confidence: 0.9)
    expect(tracker.choose(from: [farReentry]) == nil, "first far jump waits for lost budget")
    expect(tracker.choose(from: [farReentry]) == nil, "second far jump still waits for lost budget")
    expect(tracker.choose(from: [farReentry])?.id == "far-reentry", "far jump reacquires after lost budget")
    expect(tracker.predictedBox == nil, "fresh reacquisition does not use stale box prediction")

    tracker = ActiveFaceTracker()
    expect(tracker.choose(from: [current])?.id == "current", "active face reset selects current")
    expect(tracker.choose(from: [clearCompetitor, current])?.id == "winner", "clear competitor can take over")
}

private func testSignalExtractionAndFrameGate() {
    let face = FaceCandidate(id: "face", boundingBox: CGRect(x: 0.2, y: 0.25, width: 0.3, height: 0.4), confidence: 0.9)
    let landmarks = LandmarkInput(
        face: face,
        leftEye: [CGPoint(x: 0.30, y: 0.55)],
        rightEye: [CGPoint(x: 0.54, y: 0.55)],
        nose: [CGPoint(x: 0.44, y: 0.43)],
        yaw: 0.1,
        pitch: -0.05
    )
    let signal = extractSignal(from: landmarks)!
    expectClose(signal.eyeDistance, 0.24, tolerance: 0.001, "inter-eye distance is measured")
    expectClose(signal.noseOffset.x, 0.02 / 0.24, tolerance: 0.002, "nose x offset is eye-distance normalized")
    expectClose(signal.roll, 0, tolerance: 0.001, "level eyes produce zero roll")

    let closer = FaceCandidate(id: "face", boundingBox: CGRect(x: 0.15, y: 0.2, width: 0.45, height: 0.55), confidence: 0.9)
    let closerSignal = extractSignal(from: LandmarkInput(
        face: closer,
        leftEye: [CGPoint(x: 0.30, y: 0.55)],
        rightEye: [CGPoint(x: 0.54, y: 0.55)],
        nose: [CGPoint(x: 0.44, y: 0.43)],
        yaw: 0.1,
        pitch: -0.05
    ))!
    expectClose(closerSignal.noseOffset.x, signal.noseOffset.x, tolerance: 0.001, "scale alone does not change normalized nose offset")

    expect(extractSignal(from: LandmarkInput(face: face, leftEye: nil, rightEye: landmarks.rightEye, nose: landmarks.nose, yaw: nil, pitch: nil)) == nil, "missing eye landmarks reject extraction")

    let gate = FrameGate()
    expect(gate.accepts(signal, previous: nil, predictedBox: nil), "first valid signal is accepted")
    let lowConfidence = HeadSignal(signal, confidence: 0.2)
    expect(!gate.accepts(lowConfidence, previous: signal, predictedBox: signal.faceBox), "low-confidence frame is rejected")
    let jumped = HeadSignal(signal, faceBox: CGRect(x: 0.75, y: 0.25, width: 0.3, height: 0.4))
    expect(!gate.accepts(jumped, previous: signal, predictedBox: signal.faceBox), "implausible face-box jump is rejected")
    let scaled = HeadSignal(signal, faceBox: CGRect(x: 0.2, y: 0.25, width: 0.55, height: 0.75), eyeDistance: signal.eyeDistance * 2.1)
    expect(!gate.accepts(scaled, previous: signal, predictedBox: signal.faceBox), "implausible scale change is rejected")
}

private func makeSignal(x: Double, y: Double = 0, confidence: Double = 0.9) -> HeadSignal {
    HeadSignal(
        faceBox: CGRect(x: 0.3 + x * 0.02, y: 0.3, width: 0.25, height: 0.35),
        faceCenter: CGPoint(x: 0.425 + x * 0.02, y: 0.475),
        eyeMidpoint: CGPoint(x: 0.425, y: 0.55),
        eyeDistance: 0.22,
        noseOffset: CGPoint(x: x, y: y),
        roll: 0,
        yaw: x * 0.2,
        pitch: y * 0.2,
        confidence: confidence
    )
}

private func testPointerMotion() {
    let screen = CGRect(x: 0, y: 0, width: 500, height: 500)
    var pointer = HeadPointerMotion(config: .default)

    let first = pointer.step(signal: makeSignal(x: 0), timestamp: 0, screens: [screen])!
    for frame in 1...30 {
        let jitter = pointer.step(signal: makeSignal(x: frame.isMultiple(of: 2) ? 0.015 : -0.012), timestamp: Double(frame) / 30, screens: [screen])!
        expectClose(jitter.x, first.x, tolerance: 0.5, "neutral jitter does not move pointer")
    }

    let slowStart = pointer.step(signal: makeSignal(x: 0.16), timestamp: 1.1, screens: [screen])!
    let slowEnd = pointer.step(signal: makeSignal(x: 0.18), timestamp: 1.2, screens: [screen])!
    let slowDelta = slowEnd.x - slowStart.x
    let fastStart = pointer.step(signal: makeSignal(x: 0.42), timestamp: 1.3, screens: [screen])!
    let fastEnd = pointer.step(signal: makeSignal(x: 0.55), timestamp: 1.4, screens: [screen])!
    let fastDelta = fastEnd.x - fastStart.x
    expect(fastDelta > slowDelta * 2, "larger faster movement accelerates more than slow movement")

    let hysteresisHold = pointer.step(signal: makeSignal(x: 0.08), timestamp: 1.5, screens: [screen])!
    expect(hysteresisHold.x > slowEnd.x, "outer-to-inner hysteresis keeps movement active")
    let stopped = pointer.step(signal: makeSignal(x: 0.01), timestamp: 1.6, screens: [screen])!
    expectClose(stopped.x, hysteresisHold.x, tolerance: 0.5, "inner hysteresis band stops movement")

    pointer.requestRecenter()
    let recentered = pointer.step(signal: makeSignal(x: 0.35), timestamp: 1.7, screens: [screen])!
    expectClose(recentered.x, 250, tolerance: 0.5, "manual recenter centers pointer")
    let afterRecenter = pointer.step(signal: makeSignal(x: 0.35), timestamp: 1.8, screens: [screen])!
    expectClose(afterRecenter.x, recentered.x, tolerance: 0.5, "new neutral holds after recenter")

    var clamped = HeadPointerMotion(config: HeadPointerConfig(movementMode: .edge, speed: 10, distanceToEdge: 0.04))
    _ = clamped.step(signal: makeSignal(x: 0), timestamp: 0, screens: [screen])
    let nearEdge = clamped.step(signal: makeSignal(x: 2), timestamp: 2, screens: [screen, CGRect(x: 800, y: 0, width: 500, height: 500)])!
    expect(containsInclusive(screen, nearEdge) || containsInclusive(CGRect(x: 800, y: 0, width: 500, height: 500), nearEdge), "integrated pointer clamps into a real screen")

    var relative = HeadPointerMotion(config: HeadPointerConfig(movementMode: .relative, speed: 5, distanceToEdge: 0.12))
    _ = relative.step(signal: makeSignal(x: 0), timestamp: 0, screens: [screen])
    let relativeMove = relative.step(signal: makeSignal(x: 0.45), timestamp: 0.2, screens: [screen])!
    expect(relativeMove.x > 250, "relative mode moves from face translation")
}

private func testPeriodicRecenterOnlyWhileStable() {
    let screen = CGRect(x: 0, y: 0, width: 500, height: 500)
    var stable = HeadPointerMotion(config: .default)
    _ = stable.step(signal: makeSignal(x: 0), timestamp: 0, screens: [screen])
    for frame in 1...150 {
        _ = stable.step(signal: makeSignal(x: 0.04), timestamp: Double(frame) / 30, screens: [screen])
    }
    expect(
        (stable.neutralNoseOffsetXForSelfTest ?? 0) > 0,
        "stable in-band drift can slowly update neutral"
    )

    var active = HeadPointerMotion(config: .default)
    _ = active.step(signal: makeSignal(x: 0), timestamp: 0, screens: [screen])
    for frame in 1...150 {
        _ = active.step(signal: makeSignal(x: 0.4), timestamp: Double(frame) / 30, screens: [screen])
    }
    expectClose(
        active.neutralNoseOffsetXForSelfTest ?? -1,
        0,
        tolerance: 0.0001,
        "active movement does not drag neutral"
    )
}

private func testModelRecoversAfterNoFaceGap() {
    let screen = CGRect(x: 0, y: 0, width: 500, height: 500)
    var model = HeadTrackingModel()
    let initial = makeSignal(x: 0)
    let initialFace = FaceCandidate(id: "initial", boundingBox: initial.faceBox, confidence: 0.9)
    expect(model.chooseFace(from: [initialFace])?.id == "initial", "model selects initial face")
    expect(model.point(for: initial, timestamp: 0, screens: [screen]) != nil, "initial face produces a point")

    for _ in 0..<3 {
        expect(model.chooseFace(from: []) == nil, "missing face produces no candidate")
        model.missFace()
    }

    let returned = HeadSignal(
        makeSignal(x: 0.02),
        faceBox: CGRect(x: 0.78, y: 0.2, width: 0.18, height: 0.3),
        eyeDistance: 0.09
    )
    let returnedFace = FaceCandidate(id: "returned", boundingBox: returned.faceBox, confidence: 0.9)
    expect(model.chooseFace(from: [returnedFace])?.id == "returned", "model reacquires after a no-face gap")
    expect(model.point(for: returned, timestamp: 1, screens: [screen]) != nil, "freshly reacquired face is not rejected by stale geometry")
}

private func testControlCommandParsing() {
    expect(parseControlCommand(#"{"kind":"recenter"}"#) == .recenter, "recenter command parses")
    let command = parseControlCommand(#"{"kind":"config","headPointer":{"movementMode":"relative","speed":7,"distanceToEdge":0.2}}"#)
    expect(command == .config(HeadPointerConfig(movementMode: .relative, speed: 7, distanceToEdge: 0.2)), "config command parses")
}

private func runSelfTest() {
    let primary = CGRect(x: 0, y: 0, width: 100, height: 100)
    let secondary = CGRect(x: 200, y: 0, width: 100, height: 100)
    let clamped = clampIntoRealScreen(CGPoint(x: 150, y: 50), screens: [primary, secondary])
    expect(containsInclusive(primary, clamped) || containsInclusive(secondary, clamped), "gap point clamps into a real screen")

    testActiveFaceSelection()
    testSignalExtractionAndFrameGate()
    testPointerMotion()
    testPeriodicRecenterOnlyWhileStable()
    testModelRecoversAfterNoFaceGap()
    testControlCommandParsing()

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

// The capture hotkey is owned by the app process (#95), which
// spawns this sidecar only for the duration of a capture. So tracking auto-starts
// on launch and stops when the host kills the process.
private let writer = EventWriter()
private let tracker = HeadTracker(writer: writer)

NSApplication.shared.setActivationPolicy(.accessory)
startControlReader(tracker: tracker, writer: writer)
tracker.start()
RunLoop.main.run()
