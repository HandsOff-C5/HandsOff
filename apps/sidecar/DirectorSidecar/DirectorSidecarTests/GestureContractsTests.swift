//
//  GestureContractsTests.swift
//  DirectorSidecarTests
//
//  Port of packages/gesture/src/perception/parse.test.ts + fixtures.test.ts. Decodes the SAME
//  #29 recorded-frame fixtures the TS vitest goldens consume (read straight from
//  packages/gesture/fixtures via #filePath — no copied JSON, no drift) and asserts the single
//  shared `parseLandmarkFrame` reconstructs every frame's golden exactly.
//

import Testing
import Foundation
@testable import DirectorSidecar

// MARK: - Shared fixture loader (gesture lane)

enum GestureFixtures {
    static let dir: URL = {
        let path = #filePath
        let marker = "/apps/sidecar/DirectorSidecar/DirectorSidecarTests/"
        guard let range = path.range(of: marker) else {
            fatalError("Gesture fixtures: cannot locate the repo root from \(path)")
        }
        return URL(fileURLWithPath: String(path[path.startIndex..<range.lowerBound]))
            .appendingPathComponent("packages/gesture/fixtures", isDirectory: true)
    }()

    static func data(_ file: String) throws -> Data {
        try Data(contentsOf: dir.appendingPathComponent(file))
    }

    static func decode<T: Decodable>(_ type: T.Type = T.self, _ file: String) throws -> T {
        try JSONDecoder().decode(T.self, from: data(file))
    }
}

/// Float-close helper mirroring vitest `toBeCloseTo(_, digits)`: passes when |a−b| < 0.5·10⁻ᵈ.
func gClose(_ a: Double, _ b: Double, _ digits: Int = 6) -> Bool {
    abs(a - b) < 0.5 * pow(10, -Double(digits))
}

/// A raw recorded frame from `*.frames.json`: the de-normalized MediaPipe shape + its timestamp.
private struct RecordedFrame: Decodable {
    let timestampMs: Double
    let raw: LandmarkParsing.RawHandLandmarkerResult
}

// MARK: - parse.test.ts

private func rawLandmarks(_ visibility: Double?) -> [LandmarkParsing.RawLandmark] {
    (0..<21).map { i in
        LandmarkParsing.RawLandmark(x: Double(i) / 21, y: 1 - Double(i) / 21, z: Double(i - 10) / 100, visibility: visibility)
    }
}

private let rightHand = LandmarkParsing.RawHandLandmarkerResult(
    landmarks: [rawLandmarks(0.95)],
    handednesses: [[LandmarkParsing.RawCategory(categoryName: "Right", score: 0.9)]]
)

@Test func parsesOneHandRawIntoValidLandmarkFrame() throws {
    let frame = try LandmarkParsing.parseLandmarkFrame(rightHand, timestampMs: 1234)
    #expect(frame.timestampMs == 1234)
    #expect(frame.hands.count == 1)

    let hand = frame.hands[0]
    #expect(hand.handedness == .right)
    #expect(hand.score == 0.9)
    #expect(hand.landmarks.count == 21)
    #expect(hand.landmarks[5] == Contracts.Landmark(x: 5 / 21, y: 1 - 5 / 21, z: Double(5 - 10) / 100, visibility: 0.95))
}

@Test func parsesNoHandRawIntoEmptyHandsFrame() throws {
    let raw = LandmarkParsing.RawHandLandmarkerResult(landmarks: [], handednesses: [])
    let frame = try LandmarkParsing.parseLandmarkFrame(raw, timestampMs: 7)
    #expect(frame == Contracts.LandmarkFrame(timestampMs: 7, hands: []))
}

@Test func defaultsMissingLandmarkVisibilityToOne() throws {
    let raw = LandmarkParsing.RawHandLandmarkerResult(
        landmarks: [rawLandmarks(nil)],
        handednesses: [[LandmarkParsing.RawCategory(categoryName: "Left", score: 0.8)]]
    )
    let frame = try LandmarkParsing.parseLandmarkFrame(raw, timestampMs: 0)
    #expect(frame.hands[0].landmarks.allSatisfy { $0.visibility == 1 })
}

@Test func acceptsDeprecatedHandednessFieldName() throws {
    let raw = LandmarkParsing.RawHandLandmarkerResult(
        landmarks: [rawLandmarks(1)],
        handedness: [[LandmarkParsing.RawCategory(categoryName: "Left", score: 0.7)]]
    )
    let frame = try LandmarkParsing.parseLandmarkFrame(raw, timestampMs: 0)
    #expect(frame.hands[0].handedness == .left)
    #expect(frame.hands[0].score == 0.7)
}

@Test func pairsEachHandWithItsHandednessByIndex() throws {
    let raw = LandmarkParsing.RawHandLandmarkerResult(
        landmarks: [rawLandmarks(1), rawLandmarks(1)],
        handednesses: [
            [LandmarkParsing.RawCategory(categoryName: "Right", score: 0.9)],
            [LandmarkParsing.RawCategory(categoryName: "Left", score: 0.6)],
        ]
    )
    let frame = try LandmarkParsing.parseLandmarkFrame(raw, timestampMs: 0)
    #expect(frame.hands.map(\.handedness) == [.right, .left])
}

@Test func rejectsMalformedHandWrongLandmarkCount() {
    let raw = LandmarkParsing.RawHandLandmarkerResult(
        landmarks: [[LandmarkParsing.RawLandmark(x: 0, y: 0, z: 0, visibility: 1)]],
        handednesses: [[LandmarkParsing.RawCategory(categoryName: "Right", score: 0.9)]]
    )
    #expect(throws: (any Error).self) {
        try LandmarkParsing.parseLandmarkFrame(raw, timestampMs: 0)
    }
}

// MARK: - fixtures.test.ts (recorded-frame goldens)

@Test(arguments: ["no-hand", "point", "hold", "cancel", "low-confidence"])
func parserReconstructsEveryFrameGoldenExactly(_ name: String) throws {
    let recording = try GestureFixtures.decode([RecordedFrame].self, "\(name).frames.json")
    let golden = try GestureFixtures.decode([Contracts.LandmarkFrame].self, "\(name).golden.json")

    #expect(recording.count == golden.count)
    #expect(golden.count > 0)

    for (i, frame) in recording.enumerated() {
        #expect(try LandmarkParsing.parseLandmarkFrame(frame.raw, timestampMs: frame.timestampMs) == golden[i])
    }
}
