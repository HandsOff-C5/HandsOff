import AppKit
import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import QuartzCore
import Vision

struct FaceCandidate {
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

struct ActiveFaceTracker {
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

struct LandmarkInput {
    let face: FaceCandidate
    let leftEye: [CGPoint]?
    let rightEye: [CGPoint]?
    let nose: [CGPoint]?
    let yaw: Double?
    let pitch: Double?
}

struct HeadSignal {
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

func blendOptional(_ previous: Double?, _ raw: Double?, alpha: Double) -> Double? {
    guard let raw else { return previous }
    guard let previous else { return raw }
    return previous + (raw - previous) * alpha
}

func centroid(_ points: [CGPoint]?) -> CGPoint? {
    guard let points, !points.isEmpty else { return nil }
    let sum = points.reduce(CGPoint.zero) { partial, point in
        CGPoint(x: partial.x + point.x, y: partial.y + point.y)
    }
    return CGPoint(x: sum.x / Double(points.count), y: sum.y / Double(points.count))
}

func extractSignal(from input: LandmarkInput) -> HeadSignal? {
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

struct FrameGate {
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

struct SignalVector {
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

func - (lhs: SignalVector, rhs: SignalVector) -> SignalVector {
    SignalVector(x: lhs.x - rhs.x, y: lhs.y - rhs.y)
}

func + (lhs: SignalVector, rhs: SignalVector) -> SignalVector {
    SignalVector(x: lhs.x + rhs.x, y: lhs.y + rhs.y)
}

enum TrackingState {
    case acquiring
    case tracking
    case recenterPending
    case lost
}

struct HeadPointerMotion {
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

struct HeadTrackingModel {
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

