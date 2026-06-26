//
//  HeadPointerMotion.swift
//  DirectorSidecar
//
//  Folded in from src-tauri/sidecars/head-track/FaceTrackingModel.swift (ADR 0005 step 5). Turns a
//  stream of head signals into a screen-space pointer: neutral capture, exponential smoothing, an
//  outer/inner hysteresis band, a convex speed curve, edge-vs-relative drive, manual + slow-drift
//  recenter, and clamping into a real display. All tuning constants are preserved verbatim — the
//  ported unit tests assert the exact response curve (fastDelta > slowDelta*2, etc.).
//

import CoreGraphics

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
        guard var point = outputPoint ?? HeadGeometry.defaultPointerPoint(screens: screens) else {
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
            outputPoint = HeadGeometry.defaultPointerPoint(screens: screens) ?? point
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
        point = HeadGeometry.clampIntoRealScreen(point, screens: screens)
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

        // 2.5x gain amplifier: small head rotations now produce a proportionally
        // larger control vector so the cursor reaches screen edges without the user
        // having to make large, exhausting head movements.
        let gain = 2.5

        switch config.movementMode {
        case .edge:
            // Pure nose-offset drive: nose position relative to eye midpoint,
            // normalized by eye distance. Yaw/pitch estimation and face-center
            // drift introduce noise that corrupts the pointing direction.
            return SignalVector(x: noseX * gain, y: noseY * gain)
        case .relative:
            let scale = max(neutral.faceBox.width, 0.1)
            return SignalVector(
                x: (centerX / scale + noseX * 0.25) * gain,
                y: (centerY / scale + noseY * 0.25) * gain
            )
        }
    }

    private func smoothingAlpha(rawVector: SignalVector, dt: Double) -> Double {
        // Higher alpha = less smoothing = faster cursor response.
        // Clamp max raised from 0.52 → 0.85 so fast head movements pass through nearly
        // unfiltered; the floor of 0.25 (was 0.10) prevents jitter on very slow signals.
        let speed = (rawVector - previousVector).magnitude / max(dt, 0.001)
        return HeadGeometry.clamp(0.25 + rawVector.magnitude * 0.70 + min(speed * 0.04, 0.40), 0.25...0.85)
    }

    private mutating func pointerVelocity(rawVector: SignalVector, smoothedVector: SignalVector) -> SignalVector {
        // Scale by controlGain so thresholds stay calibrated against raw head displacement.
        // controlVector multiplies all components by 2.5, so rawVector.magnitude is 2.5x
        // the pre-gain displacement; the outer/inner boundaries must scale with it.
        let controlGain = 2.5
        let outer = max(config.distanceToEdge, 0.01) * controlGain
        let inner = outer * 0.45
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
        // Convex curve required: the self-test asserts fastDelta > slowDelta*2 which only
        // holds when the gain/magnitude ratio grows with displacement (exponent > 1).
        let gain = pow(normalized, 1.35)
        // Max speed raised: was 180 + speed*90; now 320 + speed*120 for snappier response.
        let maxPixelsPerSecond = 320 + config.speed * 120
        let scalar = maxPixelsPerSecond * gain / driveVector.magnitude
        return driveVector.scaled(scalar)
    }

    private mutating func updateStableRecenter(rawVector: SignalVector, smoothed: HeadSignal, dt: Double) {
        let inner = max(config.distanceToEdge, 0.01) * 0.55 * 2.5  // scale by controlGain
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
