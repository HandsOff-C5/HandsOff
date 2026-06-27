import CoreGraphics
import Foundation

/// The synthetic-testable INPUT to the hand-pointer math pipeline (`SL-3`).
///
/// Mirrors the role `FaceSignal` plays for SL-1: the pure-math half (`IndexTip`, `ActiveRegion`,
/// `CDGain`, `HandFilter`) is driven from this type with hand-built values so the math is
/// unit-testable without a camera or Vision. The Vision hand-pose lift (`HandModel`) resolves a
/// `HandSignal` from a `FrameSample` and feeds the SAME type in, so the math never changes.
///
/// All joint coordinates are **normalized `[0,1]`** in canonical CG **top-left** convention
/// (the `HandModel` lift flips Vision's bottom-left origin at the boundary, `I7`). Two joints
/// drive the 2D pointer:
///   - **`indexTip`** is the cursor source (`.indexTip`, FR-15) — used DIRECTLY, never averaged.
///   - **`indexMCP`** is a VALIDITY signal only (`IndexTip.isValid`) — its position is never used.
/// `middleTip` (`.middleTip`) is carried purely as the averaging negative-control: a cursor that
/// (wrongly) averaged index+middle tips would land between them, which the tests reject.
///
/// The EXPERIMENTAL finger-ray pointer (branch `experiment/head-ray-gaze`, `HandRayMapping`) adds
/// three refinement joints — **`indexPIP`**, **`indexDIP`** (the two middle index knuckles, for a
/// jitter-reduced pointing direction down the finger) and **`littleMCP`** (the pinky knuckle, for a
/// scale-invariant knuckle span). They are BEST-EFFORT: the lift defaults them (PIP/DIP interpolate
/// along MCP→TIP, littleMCP falls back to indexMCP) with confidence `0` when Vision can't see them,
/// so a weak refinement joint never voids the frame (only `indexTip`/`indexMCP` stay required).
public struct HandSignal: Equatable {

    /// Index fingertip (`.indexTip`) — the cursor position (`FR-15`). Used directly.
    public let indexTip: CGPoint
    /// Index metacarpophalangeal joint (`.indexMCP`) — VALIDITY (the 2D cursor) + the ray ORIGIN.
    public let indexMCP: CGPoint
    /// Middle fingertip (`.middleTip`) — carried only as the averaging negative-control.
    public let middleTip: CGPoint
    /// Index proximal interphalangeal joint (`.indexPIP`) — ray refinement (mid-finger).
    public let indexPIP: CGPoint
    /// Index distal interphalangeal joint (`.indexDIP`) — ray refinement (near the tip).
    public let indexDIP: CGPoint
    /// Little-finger metacarpophalangeal joint (`.littleMCP`) — the ray's knuckle-span anchor.
    public let littleMCP: CGPoint
    /// Confidence `0…1` of the index fingertip. The freeze gate (`FR-16`) holds below the floor.
    public let indexTipConfidence: Double
    /// Confidence `0…1` of the index MCP joint — the hand-presence validity check.
    public let indexMCPConfidence: Double
    /// Confidence `0…1` of the index PIP joint (`0` when defaulted/unseen).
    public let indexPIPConfidence: Double
    /// Confidence `0…1` of the index DIP joint (`0` when defaulted/unseen).
    public let indexDIPConfidence: Double
    /// Confidence `0…1` of the little MCP joint (`0` when defaulted/unseen).
    public let littleMCPConfidence: Double

    public init(
        indexTip: CGPoint,
        indexMCP: CGPoint,
        middleTip: CGPoint? = nil,
        indexPIP: CGPoint? = nil,
        indexDIP: CGPoint? = nil,
        littleMCP: CGPoint? = nil,
        indexTipConfidence: Double,
        indexMCPConfidence: Double,
        indexPIPConfidence: Double = 0,
        indexDIPConfidence: Double = 0,
        littleMCPConfidence: Double = 0
    ) {
        self.indexTip = indexTip
        self.indexMCP = indexMCP
        self.middleTip = middleTip ?? indexTip
        // PIP ≈ ⅓ and DIP ≈ ⅔ of the way down the MCP→TIP line when Vision can't resolve them, so
        // the refinement degrades to the plain MCP→TIP direction (the ray's documented fallback).
        self.indexPIP = indexPIP ?? CGPoint(
            x: indexMCP.x + (indexTip.x - indexMCP.x) / 3,
            y: indexMCP.y + (indexTip.y - indexMCP.y) / 3)
        self.indexDIP = indexDIP ?? CGPoint(
            x: indexMCP.x + (indexTip.x - indexMCP.x) * 2 / 3,
            y: indexMCP.y + (indexTip.y - indexMCP.y) * 2 / 3)
        // No pinky knuckle → reuse the index MCP so the span is 0 and foreshortening degrades to 0.
        self.littleMCP = littleMCP ?? indexMCP
        self.indexTipConfidence = indexTipConfidence
        self.indexMCPConfidence = indexMCPConfidence
        self.indexPIPConfidence = indexPIPConfidence
        self.indexDIPConfidence = indexDIPConfidence
        self.littleMCPConfidence = littleMCPConfidence
    }

    /// Horizontally mirror the normalized signal across the frame center (`x → 1 − x`), keeping
    /// confidences. Applied at the `HandModel.resolve(...)` boundary when `Params.capture.mirrorX`
    /// so the pointer FOLLOWS the user (selfie convention). Y is untouched. ALL joints mirror — the
    /// ray's refinement joints included — or the finger ray desyncs from the mirrored preview.
    public func mirroredX() -> HandSignal {
        HandSignal(
            indexTip: CGPoint(x: 1 - indexTip.x, y: indexTip.y),
            indexMCP: CGPoint(x: 1 - indexMCP.x, y: indexMCP.y),
            middleTip: CGPoint(x: 1 - middleTip.x, y: middleTip.y),
            indexPIP: CGPoint(x: 1 - indexPIP.x, y: indexPIP.y),
            indexDIP: CGPoint(x: 1 - indexDIP.x, y: indexDIP.y),
            littleMCP: CGPoint(x: 1 - littleMCP.x, y: littleMCP.y),
            indexTipConfidence: indexTipConfidence,
            indexMCPConfidence: indexMCPConfidence,
            indexPIPConfidence: indexPIPConfidence,
            indexDIPConfidence: indexDIPConfidence,
            littleMCPConfidence: littleMCPConfidence
        )
    }
}
