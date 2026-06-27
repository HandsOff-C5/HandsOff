// PerceptionPublisher — turns perception outputs into DirectorSidecar's bridge topic payloads.
//
// Adapted port of HO-rebuild `Models/Perception/PerceptionPublisher.swift`. The hand pointer →
// `cursorPosition` (a `Pointer`), the face gaze → `gazeFocus` (a `GazeFocus` region). The source
// targeted HandsOffLab's own contract copies; here we build DirectorSidecar's existing `Pointer` /
// `CursorPositionPayload` / `GazeFocus` / `GazeRegion` wire types directly (String-typed
// kind/state/sizeClass). The transcript path is dropped — DirectorSidecar's SpeechService owns
// transcripts, not perception.
//
// N2 — THE coordinate discipline: `PointerOutput.point` is ALREADY CG top-left, so the cursor and
// the face-derived gaze region are published with their x/y UNCHANGED. The single Cocoa→CG flip
// (`CoordinateConversion.cocoaToCG`) is applied ONLY to a Cocoa-sourced gaze RECT, never re-applied
// to an already-top-left point.
//
// I6 — a frozen face dims (low confidence, "hold last good") but its region stays centered on the
// HELD point, never (0,0).

import CoreGraphics
import Foundation

struct PerceptionPublisher {

    /// Default gaze-region extent (px) centered on the gaze point when no size class drives it.
    static let defaultGazeRegionSize = CGSize(width: 220, height: 140)

    /// The dim confidence emitted for a FROZEN face gaze so the overlay dims + holds last good.
    static let frozenDimConfidence: Double = 0.25

    /// The virtual-desktop pixel space DirectorSidecar's `Pointer` is expressed in.
    static let pointerSpace = "virtual-desktop-px"

    init() {}

    // MARK: cursorPosition (hand) — N2: point already top-left, published unchanged

    func cursorPosition(
        from output: PointerOutput,
        kind: PointerKind = .user,
        tsEpochMillis: Double = WireClock.epochMillis()
    ) -> CursorPositionPayload {
        let state: PointerState = output.state == .frozen ? .locked : .moving
        let pointer = Pointer(
            x: output.point.x, y: output.point.y, // already CG top-left — NO re-flip (N2)
            space: Self.pointerSpace,
            kind: kind.rawValue,
            agentId: nil, agentLabel: nil,
            state: state.rawValue,
            confidence: output.confidence,
            ts: tsEpochMillis)
        return CursorPositionPayload(pointers: [pointer])
    }

    // MARK: gazeFocus (face) — N2: region centered on the already-top-left point, no flip

    func gazeFocus(
        from output: PointerOutput,
        size: CGSize = PerceptionPublisher.defaultGazeRegionSize,
        sizeClass: GazeSizeClass = .region,
        tsEpochMillis: Double = WireClock.epochMillis()
    ) -> GazeFocus {
        let frozen = output.state == .frozen
        // dim + hold last good on freeze; otherwise the live confidence.
        let confidence = frozen ? Self.frozenDimConfidence : (output.confidence ?? 0)
        let region = GazeRegion(
            x: output.point.x - size.width / 2,
            y: output.point.y - size.height / 2,
            w: size.width, h: size.height)
        return GazeFocus(bounds: region, confidence: confidence,
                         sizeClass: sizeClass.rawValue, ts: tsEpochMillis)
    }

    /// THE flip path: a Cocoa (bottom-left, y-up) gaze rect → a top-left y-DOWN region via the one
    /// `cocoaToCG`. Used only when the gaze rect originates in Cocoa coordinates, never for a
    /// `PointerOutput` point (which is already top-left).
    func gazeFocus(
        fromCocoaRect rect: CGRect,
        screenHeight: Double,
        confidence: Double,
        sizeClass: GazeSizeClass = .region,
        tsEpochMillis: Double = WireClock.epochMillis()
    ) -> GazeFocus {
        let yDown = CoordinateConversion.cocoaToCG(
            cocoaBottomY: rect.origin.y, height: rect.height, screenHeight: screenHeight)
        let region = GazeRegion(x: rect.origin.x, y: yDown, w: rect.width, h: rect.height)
        return GazeFocus(bounds: region, confidence: confidence,
                         sizeClass: sizeClass.rawValue, ts: tsEpochMillis)
    }
}
