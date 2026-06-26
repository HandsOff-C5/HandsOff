//
//  LandmarkParsing.swift
//  DirectorSidecar
//
//  Port of packages/gesture/src/perception/parse.ts — the ONE parser both the live detector
//  loop and the #29 fixtures use. Turns a raw MediaPipe HandLandmarker result + capture
//  timestamp into a validated `Contracts.LandmarkFrame`. Empty `landmarks` => no-hand frame.
//  Throws (via the 21-landmark contract invariant / an invalid handedness) so bad perception
//  data can't flow downstream.
//

import Foundation

/// Raw MediaPipe HandLandmarker output shape (the subset we consume). The live Vision
/// detector (`HandLandmarkerService`) maps its observations into this; the #29 fixtures store
/// the same shape. This is the only raw shape `parseLandmarkFrame` accepts.
enum LandmarkParsing {
    /// One raw landmark. MediaPipe sometimes omits `visibility` for the hand landmarker; the
    /// parser defaults it to 1.
    struct RawLandmark: Decodable, Equatable, Sendable {
        let x: Double
        let y: Double
        let z: Double
        let visibility: Double?
    }

    struct RawCategory: Decodable, Equatable, Sendable {
        let categoryName: String
        let score: Double
    }

    struct RawHandLandmarkerResult: Decodable, Equatable, Sendable {
        /// One entry per detected hand; each its own list of landmarks.
        let landmarks: [[RawLandmark]]
        /// Current field name. One category list per hand; top category is the handedness.
        let handednesses: [[RawCategory]]?
        /// Deprecated alias still emitted by older `@mediapipe/tasks-vision` builds.
        let handedness: [[RawCategory]]?

        init(landmarks: [[RawLandmark]],
             handednesses: [[RawCategory]]? = nil,
             handedness: [[RawCategory]]? = nil) {
            self.landmarks = landmarks
            self.handednesses = handednesses
            self.handedness = handedness
        }
    }

    /// Parse a raw result + its capture timestamp into a validated `LandmarkFrame`.
    static func parseLandmarkFrame(
        _ raw: RawHandLandmarkerResult,
        timestampMs: Double
    ) throws -> Contracts.LandmarkFrame {
        let categories = raw.handednesses ?? raw.handedness ?? []

        let hands: [Contracts.Hand] = try raw.landmarks.enumerated().map { index, landmarks in
            let mapped = landmarks.map {
                Contracts.Landmark(x: $0.x, y: $0.y, z: $0.z, visibility: $0.visibility ?? 1)
            }
            let top = categories.indices.contains(index) ? categories[index].first : nil
            // TS casts `categoryName as Hand["handedness"]` then validates via zod; an absent
            // or off-vocabulary label fails the contract. score defaults to 0 (`?? 0`).
            guard let name = top?.categoryName, let handedness = Contracts.Handedness(rawValue: name) else {
                throw GestureContractError.outOfRange("handedness")
            }
            return try Contracts.Hand(landmarks: mapped, handedness: handedness, score: top?.score ?? 0)
        }

        return Contracts.LandmarkFrame(timestampMs: timestampMs, hands: hands)
    }
}
