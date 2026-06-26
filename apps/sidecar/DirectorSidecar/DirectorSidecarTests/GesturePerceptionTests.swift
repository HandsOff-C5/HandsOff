//
//  GesturePerceptionTests.swift
//  DirectorSidecarTests
//
//  Port of packages/gesture/src/perception/pointing.test.ts + head-face.test.ts.
//

import Testing
import Foundation
@testable import DirectorSidecar

// MARK: - pointing.test.ts

/// A hand whose only meaningful points are wrist (0), index MCP (5), index tip (8); the rest
/// are filler so the 21-landmark length holds.
private func handPointing() throws -> Contracts.Hand {
    var lm = Array(repeating: Contracts.Landmark(x: 0, y: 0, z: 0, visibility: 1), count: 21)
    lm[0] = Contracts.Landmark(x: 0.2, y: 0.8, z: 0, visibility: 1) // wrist
    lm[5] = Contracts.Landmark(x: 0.4, y: 0.6, z: 0, visibility: 1) // index MCP
    lm[8] = Contracts.Landmark(x: 0.5, y: 0.5, z: 0, visibility: 1) // index tip
    return try Contracts.Hand(landmarks: lm, handedness: .right, score: 0.9)
}

@Test func pointingSignalDefaultsToIndexFingertip() throws {
    #expect(try GesturePointing.pointingSignal(handPointing()) == Vec2(0.5, 0.5))
}

@Test func pointingSignalExtendsAlongWristToTipRay() throws {
    let s = try GesturePointing.pointingSignal(handPointing(), .init(anchor: .wrist, ext: 1))
    #expect(gClose(s.x, 0.8))
    #expect(gClose(s.y, 0.2))
}

@Test func pointingSignalUsesIndexMcpAnchor() throws {
    let s = try GesturePointing.pointingSignal(handPointing(), .init(anchor: .indexMcp, ext: 1))
    #expect(gClose(s.x, 0.6))
    #expect(gClose(s.y, 0.4))
}

@Test func reliabilityIsScoreWhenEndpointsVisible() throws {
    #expect(gClose(try GesturePointing.pointingReliability(handPointing()), 0.9))
}

@Test func reliabilityFallsWhenIndexTipOccluded() throws {
    var lm = try handPointing().landmarks
    lm[8] = Contracts.Landmark(x: lm[8].x, y: lm[8].y, z: lm[8].z, visibility: 0.2)
    let hand = try Contracts.Hand(landmarks: lm, handedness: .right, score: 0.9)
    #expect(gClose(try GesturePointing.pointingReliability(hand), 0.18))
}

@Test func reliabilityFallsWhenAnchorOccluded() throws {
    var lm = try handPointing().landmarks
    lm[0] = Contracts.Landmark(x: lm[0].x, y: lm[0].y, z: lm[0].z, visibility: 0.1)
    let hand = try Contracts.Hand(landmarks: lm, handedness: .right, score: 0.9)
    #expect(gClose(try GesturePointing.pointingReliability(hand, .init(anchor: .wrist)), 0.09))
}

@Test func reliabilityReadsIndexMcpVisibilityForThatAnchor() throws {
    var lm = try handPointing().landmarks
    lm[0] = Contracts.Landmark(x: lm[0].x, y: lm[0].y, z: lm[0].z, visibility: 0.1) // wrist unused
    lm[5] = Contracts.Landmark(x: lm[5].x, y: lm[5].y, z: lm[5].z, visibility: 0.5)
    let hand = try Contracts.Hand(landmarks: lm, handedness: .right, score: 0.9)
    #expect(gClose(try GesturePointing.pointingReliability(hand, .init(anchor: .indexMcp)), 0.45))
}

@Test func reliabilityCappedByLowDetectionScore() throws {
    let hand = try Contracts.Hand(landmarks: try handPointing().landmarks, handedness: .right, score: 0.3)
    #expect(gClose(try GesturePointing.pointingReliability(hand), 0.3))
}

/// Index/middle pose hand: fingers point up from a wrist at the bottom; "extended" when the
/// tip is farther from the wrist than its PIP, "curled" when closer. Only index (6→8) and
/// middle (10→12) are read; the rest are filler.
private func poseHand(_ indexTipY: Double, _ indexPipY: Double, _ middleTipY: Double, _ middlePipY: Double) throws -> Contracts.Hand {
    var lm = Array(repeating: Contracts.Landmark(x: 0.5, y: 0.5, z: 0, visibility: 1), count: 21)
    lm[0] = Contracts.Landmark(x: 0.5, y: 0.9, z: 0, visibility: 1)
    lm[6] = Contracts.Landmark(x: 0.5, y: indexPipY, z: 0, visibility: 1)
    lm[8] = Contracts.Landmark(x: 0.5, y: indexTipY, z: 0, visibility: 1)
    lm[10] = Contracts.Landmark(x: 0.5, y: middlePipY, z: 0, visibility: 1)
    lm[12] = Contracts.Landmark(x: 0.5, y: middleTipY, z: 0, visibility: 1)
    return try Contracts.Hand(landmarks: lm, handedness: .right, score: 0.9)
}

@Test func isPointingPoseTrueForIndexPoint() throws {
    #expect(try GesturePointing.isPointingPose(poseHand(0.4, 0.6, 0.7, 0.55)) == true)
}

@Test func isPointingPoseFalseForOpenPalm() throws {
    #expect(try GesturePointing.isPointingPose(poseHand(0.4, 0.6, 0.35, 0.55)) == false)
}

@Test func isPointingPoseFalseForFist() throws {
    #expect(try GesturePointing.isPointingPose(poseHand(0.7, 0.6, 0.7, 0.55)) == false)
}

@Test func pointingSignalFromFrameNullForNoHand() throws {
    #expect(try GesturePointing.pointingSignalFromFrame(Contracts.LandmarkFrame(timestampMs: 0, hands: [])) == nil)
}

@Test func pointingSignalFromFrameUsesFirstHand() throws {
    let frame = Contracts.LandmarkFrame(timestampMs: 0, hands: [try handPointing()])
    #expect(try GesturePointing.pointingSignalFromFrame(frame) == Vec2(0.5, 0.5))
}

@Test func pointingSignalFromPointFixtureFrame() throws {
    let golden = try GestureFixtures.decode([Contracts.LandmarkFrame].self, "point.golden.json")
    let s = try #require(try GesturePointing.pointingSignalFromFrame(golden[0]))
    #expect(gClose(s.x, 0.31))
    #expect(gClose(s.y, 0.53))
}

// MARK: - head-face.test.ts

private struct HeadFaceRecorded: Decodable {
    let timestampMs: Double
    let raw: HeadFaceParsing.RawFrame
}

/// Validates `attentionRegionCandidateSchema` shape (head-pointing.ts) for the golden's extra
/// `candidates` — decode == validate. Mirrors the existing top-level `AttentionRegionCandidate`
/// (Attention/AttentionRegion.swift), which is a computed value type, not a decoder.
private struct GoldenAttentionCandidate: Decodable {
    let surface: Contracts.SurfaceSnapshot
    let score: Double
    let distance: Double
}

/// Golden frame: the parsed cue shape + the extra `candidates` validated separately.
private struct HeadFaceGolden: Decodable {
    let timestampMs: Double
    let cues: [HeadFaceCue]
    let candidates: [GoldenAttentionCandidate]
}

private func closeOpt(_ a: Double?, _ b: Double?) -> Bool {
    switch (a, b) {
    case (nil, nil): return true
    case let (x?, y?): return gClose(x, y)
    default: return false
    }
}

private func closePoint(_ a: HeadFacePoint, _ b: HeadFacePoint) -> Bool {
    gClose(a.x, b.x) && gClose(a.y, b.y) && gClose(a.z, b.z) && gClose(a.visibility, b.visibility)
}

private func closePoints(_ a: [HeadFacePoint], _ b: [HeadFacePoint]) -> Bool {
    a.count == b.count && zip(a, b).allSatisfy(closePoint)
}

private func closeCue(_ a: HeadFaceCue, _ b: HeadFaceCue) -> Bool {
    a.id == b.id
        && gClose(a.confidence, b.confidence)
        && gClose(a.box.x, b.box.x) && gClose(a.box.y, b.box.y)
        && gClose(a.box.width, b.box.width) && gClose(a.box.height, b.box.height)
        && closePoint(a.center, b.center)
        && closePoints(a.landmarks.leftEye, b.landmarks.leftEye)
        && closePoints(a.landmarks.rightEye, b.landmarks.rightEye)
        && closePoints(a.landmarks.nose, b.landmarks.nose)
        && a.landmarkAvailability == b.landmarkAvailability
        && optPoint(a.eyeMidpoint, b.eyeMidpoint)
        && closeOpt(a.eyeDistance, b.eyeDistance)
        && optVec(a.noseOffset, b.noseOffset)
        && closeOpt(a.yaw, b.yaw)
        && closeOpt(a.pitch, b.pitch)
}

private func optPoint(_ a: HeadFacePoint?, _ b: HeadFacePoint?) -> Bool {
    switch (a, b) {
    case (nil, nil): return true
    case let (x?, y?): return closePoint(x, y)
    default: return false
    }
}

private func optVec(_ a: HeadFaceVector?, _ b: HeadFaceVector?) -> Bool {
    switch (a, b) {
    case (nil, nil): return true
    case let (x?, y?): return gClose(x.x, y.x) && gClose(x.y, y.y)
    default: return false
    }
}

@Test(arguments: ["head-face-present", "head-face-none", "head-face-off-axis", "head-face-low-confidence"])
func headFaceParserReconstructsCueGolden(_ name: String) throws {
    let recording = try GestureFixtures.decode([HeadFaceRecorded].self, "\(name).frames.json")
    let golden = try GestureFixtures.decode([HeadFaceGolden].self, "\(name).golden.json")

    #expect(recording.count == golden.count)
    #expect(golden.count > 0)

    for (index, frame) in recording.enumerated() {
        let expected = golden[index]
        let parsed = try HeadFaceParsing.parseHeadFaceFrame(frame.raw, timestampMs: frame.timestampMs)
        #expect(gClose(parsed.timestampMs, expected.timestampMs))
        #expect(parsed.cues.count == expected.cues.count)
        for (a, b) in zip(parsed.cues, expected.cues) {
            #expect(closeCue(a, b))
        }
        // The fixtures' candidates must remain contract-valid (decode == validate here).
        #expect(expected.candidates.count == golden[index].candidates.count)
    }
}

@Test func headFaceFixtureSetStaysSmall() throws {
    let names = ["head-face-present", "head-face-none", "head-face-off-axis", "head-face-low-confidence"]
    let total = try names.flatMap { ["\($0).frames.json", "\($0).golden.json"] }
        .reduce(0) { $0 + (try GestureFixtures.data($1).count) }
    #expect(total < 20_000)
}

@Test func headFaceRejectsMalformedConfidence() {
    let raw = HeadFaceParsing.RawFrame(faces: [
        HeadFaceParsing.RawCandidate(
            id: "bad-face",
            confidence: 1.2,
            boundingBox: HeadFaceBox(x: 0.4, y: 0.2, width: 0.2, height: 0.3),
            landmarks: HeadFaceParsing.RawLandmarks(
                leftEye: [HeadFaceParsing.RawPoint(x: 0.46, y: 0.32, z: nil, visibility: nil)],
                rightEye: [HeadFaceParsing.RawPoint(x: 0.56, y: 0.32, z: nil, visibility: nil)],
                nose: [HeadFaceParsing.RawPoint(x: 0.51, y: 0.42, z: nil, visibility: nil)]
            ),
            yaw: nil,
            pitch: nil
        ),
    ])
    #expect(throws: (any Error).self) {
        try HeadFaceParsing.parseHeadFaceFrame(raw, timestampMs: 0)
    }
}
