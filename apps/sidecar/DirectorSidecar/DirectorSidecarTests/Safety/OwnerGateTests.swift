//
//  OwnerGateTests.swift
//  DirectorSidecarTests
//
//  Verifies the OwnerGate speaker-verification policy core (INVARIANT I-OG).
//  Tests are pure/static — no mic, no live embedding backend. All cases exercise the
//  gate policy directly, including the regression guard for the forbidden fixture stub
//  that silently admitted an empty embedding `[]` as valid.

import Testing
@testable import DirectorSidecar

struct OwnerGateTests {

    // MARK: - enforce mode: not yet enrolled

    /// Attempting to verify before any enrollment → denied (no voiceprint on record).
    @Test func enforce_notEnrolled_denied() {
        let gate = OwnerGate(mode: .enforce)
        let result = gate.verify([0.1, 0.2, 0.3])
        #expect(result == .denied(reason: "no owner enrolled"))
    }

    // MARK: - enforce mode: successful admission

    /// Enrolling and then verifying the identical embedding → admitted.
    @Test func enforce_enrollThenVerifySameEmbedding_admitted() {
        let gate = OwnerGate(mode: .enforce, threshold: 0.75)
        let vec: [Float] = [1.0, 0.0, 0.0]
        gate.enroll(vec)
        #expect(gate.verify(vec) == .admitted)
    }

    // MARK: - enforce mode: below-threshold rejection

    /// An orthogonal vector (cosine similarity ≈ 0) should be denied.
    @Test func enforce_orthogonalEmbedding_denied() {
        let gate = OwnerGate(mode: .enforce, threshold: 0.75)
        gate.enroll([1.0, 0.0, 0.0])
        let orthogonal: [Float] = [0.0, 1.0, 0.0]
        let result = gate.verify(orthogonal)
        #expect(result == .denied(reason: "below threshold"))
    }

    // MARK: - THE REGRESSION GUARD (forbidden fixture stub bug)

    /// Empty embedding → denied in enforce mode, ALWAYS, even before enrollment.
    /// This is the exact bug the prior forbidden fixture stub introduced: it silently
    /// admitted `[]` as valid. That must never happen.
    @Test func enforce_emptyEmbedding_alwaysDenied() {
        let gate = OwnerGate(mode: .enforce)
        // No enrollment — should still be categorically denied for empty, not "no owner enrolled"
        let result = gate.verify([])
        #expect(result == .denied(reason: "empty embedding"))
    }

    /// Empty embedding is denied even after a valid owner is enrolled.
    @Test func enforce_emptyEmbedding_deniedEvenWhenEnrolled() {
        let gate = OwnerGate(mode: .enforce, threshold: 0.75)
        gate.enroll([1.0, 0.0])
        let result = gate.verify([])
        // Empty is checked BEFORE similarity — must not reach "below threshold"
        #expect(result == .denied(reason: "empty embedding"))
    }

    // MARK: - Enrollment rejects empty embeddings

    /// `enroll([])` returns false and leaves `isEnrolled` false.
    @Test func enroll_emptyEmbedding_rejected() {
        let gate = OwnerGate(mode: .enforce)
        let accepted = gate.enroll([])
        #expect(accepted == false)
        #expect(gate.isEnrolled == false)
    }

    /// A non-empty enrollment sets `isEnrolled`.
    @Test func enroll_nonEmpty_setsIsEnrolled() {
        let gate = OwnerGate(mode: .enforce)
        #expect(gate.isEnrolled == false)
        gate.enroll([0.5, 0.5])
        #expect(gate.isEnrolled == true)
    }

    // MARK: - Cosine similarity geometry

    /// Identical non-zero vectors have cosine similarity ≈ 1.0.
    @Test func cosineSimilarity_identical_nearOne() {
        let vec: [Float] = [3.0, 4.0, 0.0]
        let score = cosineSimilarity(vec, vec)
        #expect(abs(score - 1.0) < 1e-6)
    }

    /// Orthogonal vectors have cosine similarity ≈ 0.0.
    @Test func cosineSimilarity_orthogonal_nearZero() {
        let a: [Float] = [1.0, 0.0]
        let b: [Float] = [0.0, 1.0]
        let score = cosineSimilarity(a, b)
        #expect(abs(score - 0.0) < 1e-6)
    }

    /// Empty vectors return 0.0 — safely below any threshold, never spuriously admitted.
    @Test func cosineSimilarity_emptyVectors_returnsZero() {
        let score = cosineSimilarity([], [])
        #expect(score == 0.0)
    }

    // MARK: - auditedBypass mode

    /// auditedBypass returns `.bypassed`, not `.admitted`, for any embedding.
    /// This proves bypass is NOT silent — it is distinguishable from genuine admission.
    @Test func auditedBypass_returnsBypassed_notAdmitted() {
        let gate = OwnerGate(mode: .auditedBypass)
        let result = gate.verify([1.0, 0.0])
        // Must be .bypassed, NOT .admitted — the audit trail depends on this distinction.
        #expect(result == .bypassed)
        #expect(result != .admitted)
    }

    /// auditedBypass returns `.bypassed` even for an empty embedding — bypass is explicit,
    /// but the caller must still log it; it is never silently treated as admission.
    @Test func auditedBypass_emptyEmbedding_returnsBypassed() {
        let gate = OwnerGate(mode: .auditedBypass)
        let result = gate.verify([])
        #expect(result == .bypassed)
    }

    /// auditedBypass returns `.bypassed` even when no owner is enrolled — again, caller
    /// must audit. The gate never pretends this is a real voiceprint match.
    @Test func auditedBypass_notEnrolled_returnsBypassed() {
        let gate = OwnerGate(mode: .auditedBypass)
        #expect(gate.isEnrolled == false)
        #expect(gate.verify([0.5, 0.5]) == .bypassed)
    }
}
