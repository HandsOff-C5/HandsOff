//
//  FaceSelection.swift
//  DirectorSidecar
//
//  Folded in from src-tauri/sidecars/head-track/FaceTrackingModel.swift (ADR 0005 step 5). Tracks
//  ONE active face across frames: resists slight-confidence competitors, predicts the next box from
//  velocity, and only switches/reacquires after a lost-frame budget. Pure value type, mutated on the
//  camera's video queue (single-threaded there) — no isolation needed.
//

import CoreGraphics

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
        let iou = HeadGeometry.intersectionOverUnion(candidate.boundingBox, box)
        let centerDistance = HeadGeometry.distance(HeadGeometry.center(candidate.boundingBox), HeadGeometry.center(box))
        let scale = abs(sqrt(HeadGeometry.area(candidate.boundingBox)) - sqrt(HeadGeometry.area(box)))
        return iou * 1.4 - centerDistance * 1.1 - scale * 0.5
    }
}
