//
//  HandLandmarks.swift
//  DirectorSidecar
//
//  Port of the @handsoff/contracts referent.ts hand-landmark schemas — the gesture
//  lane's perception INPUT side: `Landmark`, `Handedness`, `Hand`, `LandmarkFrame`.
//  These mirror the MediaPipe Hand Landmarker output the single `parseLandmarkFrame`
//  produces (see Gesture/LandmarkParsing.swift) and the #29 recorded-frame fixtures
//  decode into.
//
//  Namespaced under `Contracts.` like every other @handsoff/contracts port (PORTING.md
//  note 4 "namespace, don't collide"); the gesture algorithm types stay top-level in
//  Gesture/. The Referent.swift port deliberately deferred these to the gesture lane —
//  this file closes that gap.
//
//  Drift guard: GestureContractsDecodeTests decodes the real golden/frames JSON. The
//  21-landmark length invariant (zod `.length(21)`) is enforced at decode AND at the
//  in-code validating init, so a malformed hand throws loudly rather than flowing on.
//

import Foundation

extension Contracts {
    /// One hand landmark — MediaPipe NormalizedLandmark: x/y normalized to [0,1], z is
    /// relative depth (wrist origin), visibility in [0,1]. (The [0,1] bounds are enforced
    /// TS-side; decode keeps the raw value, matching the SelectedReferent convention.)
    struct Landmark: Codable, Equatable, Sendable {
        let x: Double
        let y: Double
        let z: Double
        let visibility: Double
    }

    /// MediaPipe handedness label. Raw wire values are capitalized ("Left"/"Right").
    enum Handedness: String, Codable, Sendable, CaseIterable {
        case left = "Left"
        case right = "Right"
    }

    /// One detected hand: exactly 21 landmarks plus handedness and its detection score.
    /// The `.length(21)` zod invariant is the structural gate the perception parser relies
    /// on (a malformed hand must not reach calibration/pointing), so it throws here.
    struct Hand: Decodable, Equatable, Sendable {
        let landmarks: [Landmark]
        let handedness: Handedness
        let score: Double

        enum CodingKeys: String, CodingKey { case landmarks, handedness, score }

        /// Validating in-code initializer used by `parseLandmarkFrame`.
        init(landmarks: [Landmark], handedness: Handedness, score: Double) throws {
            guard landmarks.count == 21 else {
                throw GestureContractError.invalidLandmarkCount(landmarks.count)
            }
            self.landmarks = landmarks
            self.handedness = handedness
            self.score = score
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let landmarks = try c.decode([Landmark].self, forKey: .landmarks)
            guard landmarks.count == 21 else {
                throw GestureContractError.invalidLandmarkCount(landmarks.count)
            }
            self.landmarks = landmarks
            self.handedness = try c.decode(Handedness.self, forKey: .handedness)
            self.score = try c.decode(Double.self, forKey: .score)
        }
    }

    /// One parsed perception frame — the output of the single `parseLandmarkFrame` the
    /// runtime and the #29 fixtures both consume. Empty `hands` = no hand detected.
    struct LandmarkFrame: Decodable, Equatable, Sendable {
        let timestampMs: Double
        let hands: [Hand]

        init(timestampMs: Double, hands: [Hand]) {
            self.timestampMs = timestampMs
            self.hands = hands
        }
    }
}

/// Errors raised while validating gesture-lane contract data at the perception boundary.
enum GestureContractError: Error, Equatable {
    case invalidLandmarkCount(Int)
    case missingLandmark(Int)
    case nonFinite(String)
    case outOfRange(String)
}
