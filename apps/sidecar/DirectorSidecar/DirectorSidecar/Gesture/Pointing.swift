//
//  Pointing.swift
//  DirectorSidecar
//
//  Port of packages/gesture/src/perception/pointing.ts — the landmark→pointing-ray extractor.
//  Pure: turns a detected `Hand` into the 2D raw pointing signal (normalized image coords)
//  that the calibration affine maps to a screen point. No camera, no clock. 2D only — robust
//  for a front-facing camera and unaffected by depth (z) noise.
//

import Foundation

enum GesturePointing {
    // MediaPipe hand-landmark indices (the standard 21-point topology).
    private static let wrist = 0
    private static let indexFingerMCP = 5
    private static let indexFingerPIP = 6
    private static let indexFingerTip = 8
    private static let middleFingerPIP = 10
    private static let middleFingerTip = 12

    /// Ray anchor: the wrist (whole-hand direction) or the index MCP (finger-only).
    enum Anchor {
        case wrist
        case indexMcp
    }

    struct Options {
        /// The ray runs anchor → index tip. Default `.wrist`.
        var anchor: Anchor
        /// How far past the fingertip to project along the ray, in ray-length units. 0 = the
        /// fingertip itself; 1 = one ray-length beyond it. Default 0 — calibration absorbs the rest.
        var ext: Double
        /// Which hand to read in `pointingSignalFromFrame`. Default: the first detected hand.
        var handedness: Contracts.Handedness?

        init(anchor: Anchor = .wrist, ext: Double = 0, handedness: Contracts.Handedness? = nil) {
            self.anchor = anchor
            self.ext = ext
            self.handedness = handedness
        }
    }

    private static func xy(_ hand: Contracts.Hand, _ index: Int) throws -> Vec2 {
        guard hand.landmarks.indices.contains(index) else {
            throw GestureContractError.missingLandmark(index)
        }
        let l = hand.landmarks[index]
        return Vec2(l.x, l.y)
    }

    private static func visibilityOf(_ hand: Contracts.Hand, _ index: Int) throws -> Double {
        guard hand.landmarks.indices.contains(index) else {
            throw GestureContractError.missingLandmark(index)
        }
        return hand.landmarks[index].visibility
    }

    /// How trustworthy this frame's pointing ray is, in [0,1] — the hand channel's fusion
    /// weight (seam to gaze/voice late-fusion). The detection score scaled by the LEAST-visible
    /// of the ray's two endpoints (anchor + index tip): with one camera, an occluded endpoint
    /// makes the ray DIRECTION unreliable even at a high detection score, so the weight falls.
    static func pointingReliability(_ hand: Contracts.Hand, _ options: Options = Options()) throws -> Double {
        let anchorVis = try visibilityOf(hand, options.anchor == .wrist ? wrist : indexFingerMCP)
        let tipVis = try visibilityOf(hand, indexFingerTip)
        return hand.score * min(anchorVis, tipVis)
    }

    private static func distToWrist(_ hand: Contracts.Hand, _ index: Int) throws -> Double {
        let w = try xy(hand, wrist)
        let p = try xy(hand, index)
        return (p.x - w.x).hypot(with: p.y - w.y)
    }

    /// A finger is extended when its tip reaches farther from the wrist than its PIP joint.
    private static func fingerExtended(_ hand: Contracts.Hand, _ tip: Int, _ pip: Int) throws -> Bool {
        try distToWrist(hand, tip) > distToWrist(hand, pip)
    }

    /// Is the hand making a deliberate index-pointing gesture? Index extended AND middle curled
    /// — what distinguishes a point from an open/raised hand (all extended) or a fist (none).
    /// The referent loop arms a lock only while this holds (#25 perception gate).
    static func isPointingPose(_ hand: Contracts.Hand) throws -> Bool {
        try fingerExtended(hand, indexFingerTip, indexFingerPIP)
            && !(try fingerExtended(hand, middleFingerTip, middleFingerPIP))
    }

    /// Derive the raw pointing signal from one hand.
    static func pointingSignal(_ hand: Contracts.Hand, _ options: Options = Options()) throws -> Vec2 {
        let t = try xy(hand, indexFingerTip)
        let a = try xy(hand, options.anchor == .wrist ? wrist : indexFingerMCP)
        return Vec2(t.x + options.ext * (t.x - a.x), t.y + options.ext * (t.y - a.y))
    }

    /// Derive the pointing signal from a parsed frame, or nil when no hand is present (or the
    /// requested handedness is absent).
    static func pointingSignalFromFrame(
        _ frame: Contracts.LandmarkFrame,
        _ options: Options = Options()
    ) throws -> Vec2? {
        let hand = handFor(frame, options.handedness)
        guard let hand else { return nil }
        return try pointingSignal(hand, options)
    }

    /// The hand a frame-level read targets: the requested handedness, else the first detected.
    static func handFor(_ frame: Contracts.LandmarkFrame, _ handedness: Contracts.Handedness?) -> Contracts.Hand? {
        if let handedness {
            return frame.hands.first { $0.handedness == handedness }
        }
        return frame.hands.first
    }
}

private extension Double {
    /// `Math.hypot(self, other)` — matches the TS reliability/distance math exactly.
    func hypot(with other: Double) -> Double { Foundation.hypot(self, other) }
}
