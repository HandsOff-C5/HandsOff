//
//  HeadFaceParsing.swift
//  DirectorSidecar
//
//  Port of packages/gesture/src/perception/head-face.ts — parses raw face-detection output
//  (bounding box + optional eye/nose landmark groups) into normalized head/face cues: box
//  center, per-group centroids, eye midpoint/distance, and the nose offset (the off-axis head
//  signal). Pure + validating: malformed confidence/box/coordinates throw before reaching
//  fusion. The parsed cues are compared field-by-field (float tolerance) against the #29
//  head-face golden, whose extra `candidates` validate as `Contracts.AttentionRegionCandidate`.
//

import Foundation

struct HeadFacePoint: Codable, Equatable, Sendable {
    let x: Double
    let y: Double
    let z: Double
    let visibility: Double
}

struct HeadFaceBox: Codable, Equatable, Sendable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}

struct HeadFaceVector: Codable, Equatable, Sendable {
    let x: Double
    let y: Double
}

struct HeadFaceLandmarks: Codable, Equatable, Sendable {
    let leftEye: [HeadFacePoint]
    let rightEye: [HeadFacePoint]
    let nose: [HeadFacePoint]
}

struct HeadFaceAvailability: Codable, Equatable, Sendable {
    let leftEye: Bool
    let rightEye: Bool
    let nose: Bool
}

struct HeadFaceCue: Codable, Equatable, Sendable {
    let id: String
    let confidence: Double
    let box: HeadFaceBox
    let center: HeadFacePoint
    let landmarks: HeadFaceLandmarks
    let landmarkAvailability: HeadFaceAvailability
    let eyeMidpoint: HeadFacePoint?
    let eyeDistance: Double?
    let noseOffset: HeadFaceVector?
    let yaw: Double?
    let pitch: Double?
}

struct HeadFaceFrame: Codable, Equatable, Sendable {
    let timestampMs: Double
    let cues: [HeadFaceCue]
}

// MARK: - Raw input shapes

enum HeadFaceParsing {
    struct RawPoint: Decodable, Sendable {
        let x: Double
        let y: Double
        let z: Double?
        let visibility: Double?
    }

    struct RawLandmarks: Decodable, Sendable {
        let leftEye: [RawPoint]?
        let rightEye: [RawPoint]?
        let nose: [RawPoint]?
    }

    struct RawCandidate: Decodable, Sendable {
        let id: String?
        let confidence: Double
        let boundingBox: HeadFaceBox
        let landmarks: RawLandmarks?
        let yaw: Double?
        let pitch: Double?
    }

    struct RawFrame: Decodable, Sendable {
        let faces: [RawCandidate]
    }

    static func parseHeadFaceFrame(_ raw: RawFrame, timestampMs: Double) throws -> HeadFaceFrame {
        try finite("timestampMs", timestampMs)
        let cues = try raw.faces.enumerated().map { index, face in try parseFace(face, index) }
        return HeadFaceFrame(timestampMs: timestampMs, cues: cues)
    }

    private static func parseFace(_ face: RawCandidate, _ index: Int) throws -> HeadFaceCue {
        try confidence(face.confidence)
        try box(face.boundingBox)

        let landmarks = HeadFaceLandmarks(
            leftEye: try points(face.landmarks?.leftEye ?? []),
            rightEye: try points(face.landmarks?.rightEye ?? []),
            nose: try points(face.landmarks?.nose ?? [])
        )
        let leftEye = centroid(landmarks.leftEye)
        let rightEye = centroid(landmarks.rightEye)
        let nose = centroid(landmarks.nose)
        var eyeMidpoint: HeadFacePoint?
        var eyeDistance: Double?
        if let l = leftEye, let r = rightEye {
            eyeMidpoint = try point((l.x + r.x) / 2, (l.y + r.y) / 2)
            eyeDistance = hypot(r.x - l.x, r.y - l.y)
        }

        let noseOffset: HeadFaceVector?
        if let mid = eyeMidpoint, let nose, let d = eyeDistance, d > 0 {
            noseOffset = HeadFaceVector(x: (nose.x - mid.x) / d, y: (nose.y - mid.y) / d)
        } else {
            noseOffset = nil
        }

        return HeadFaceCue(
            id: face.id ?? "face-\(index)",
            confidence: face.confidence,
            box: face.boundingBox,
            center: try point(
                face.boundingBox.x + face.boundingBox.width / 2,
                face.boundingBox.y + face.boundingBox.height / 2
            ),
            landmarks: landmarks,
            landmarkAvailability: HeadFaceAvailability(
                leftEye: !landmarks.leftEye.isEmpty,
                rightEye: !landmarks.rightEye.isEmpty,
                nose: !landmarks.nose.isEmpty
            ),
            eyeMidpoint: eyeMidpoint,
            eyeDistance: eyeDistance,
            noseOffset: noseOffset,
            yaw: try nullableFinite("yaw", face.yaw),
            pitch: try nullableFinite("pitch", face.pitch)
        )
    }

    private static func points(_ raw: [RawPoint]) throws -> [HeadFacePoint] {
        try raw.map { p in
            let z = p.z ?? 0
            let visibility = p.visibility ?? 1
            try finite("x", p.x)
            try finite("y", p.y)
            try finite("z", z)
            try confidence(visibility, "visibility")
            return HeadFacePoint(x: p.x, y: p.y, z: z, visibility: visibility)
        }
    }

    private static func centroid(_ points: [HeadFacePoint]) -> HeadFacePoint? {
        guard !points.isEmpty else { return nil }
        var sx = 0.0, sy = 0.0, sz = 0.0, sv = 0.0
        for p in points { sx += p.x; sy += p.y; sz += p.z; sv += p.visibility }
        let n = Double(points.count)
        return HeadFacePoint(x: sx / n, y: sy / n, z: sz / n, visibility: sv / n)
    }

    private static func point(_ x: Double, _ y: Double) throws -> HeadFacePoint {
        try finite("x", x)
        try finite("y", y)
        return HeadFacePoint(x: x, y: y, z: 0, visibility: 1)
    }

    private static func box(_ value: HeadFaceBox) throws {
        try finite("box.x", value.x)
        try finite("box.y", value.y)
        try finite("box.width", value.width)
        try finite("box.height", value.height)
        if value.width <= 0 || value.height <= 0 {
            throw GestureContractError.outOfRange("face bounding box width and height must be positive")
        }
    }

    private static func confidence(_ value: Double, _ name: String = "confidence") throws {
        try finite(name, value)
        if value < 0 || value > 1 {
            throw GestureContractError.outOfRange("\(name) must be between 0 and 1")
        }
    }

    private static func nullableFinite(_ name: String, _ value: Double?) throws -> Double? {
        guard let value else { return nil }
        try finite(name, value)
        return value
    }

    private static func finite(_ name: String, _ value: Double) throws {
        if !value.isFinite {
            throw GestureContractError.nonFinite("\(name) must be finite")
        }
    }
}
