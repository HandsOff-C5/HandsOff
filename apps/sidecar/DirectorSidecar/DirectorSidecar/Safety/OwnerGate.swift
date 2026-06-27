//
//  OwnerGate.swift
//  DirectorSidecar
//
//  Speaker-verification authorization gate — FAIL-CLOSED owner-voice policy.
//
//  INVARIANT (I-OG): only the enrolled owner's voiceprint may authorize mutating actions.
//  Empty embeddings are categorically rejected in enforce mode — this guards the regression
//  introduced by the prior forbidden fixture stub that silently admitted `[]` as valid.
//
//  Embedding EXTRACTION is an injected dependency (a live backend seam, like the other
//  Live* backends in this app). The gate POLICY is pure, dependency-free, and fully tested.
//
//  MODES:
//  • enforce      — real cosine-similarity verification; fails closed on empty or unmatched.
//  • auditedBypass — an EXPLICIT, named, non-silent operator escape hatch for contexts where
//                    no embedding source exists (e.g. demo mode). Returns `.bypassed`, NOT
//                    `.admitted`, so audit logs can surface every bypass. Any bypass must be
//                    logged by the caller. This is NOT a silent fixture stub.

import Foundation

// MARK: - VoiceEmbedding

/// A speaker voiceprint embedding — a dense float vector produced by a speaker encoder model.
/// Extraction is an injected Live* dependency; this type carries only the policy-relevant data.
struct VoiceEmbedding: Equatable, Sendable {
    let values: [Float]
}

// MARK: - Cosine Similarity

/// Cosine similarity between two float vectors, in [−1, 1].
/// Returns 0.0 for empty inputs or zero-norm vectors — safely below any real threshold,
/// so malformed embeddings never gain spurious similarity scores.
func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Double {
    guard a.count == b.count, !a.isEmpty else { return 0.0 }
    var dot: Double = 0
    var normA: Double = 0
    var normB: Double = 0
    for i in 0 ..< a.count {
        let ai = Double(a[i])
        let bi = Double(b[i])
        dot   += ai * bi
        normA += ai * ai
        normB += bi * bi
    }
    let denom = normA.squareRoot() * normB.squareRoot()
    guard denom > 0 else { return 0.0 }
    return dot / denom
}

// MARK: - OwnerGate

/// Speaker-verification authorization gate: only the enrolled owner's voice may admit
/// mutating actions into the loop.
///
/// **Enforce mode — FAIL CLOSED**
///   - `.denied(reason: "empty embedding")`   — empty vector always denied; regression guard.
///   - `.denied(reason: "no owner enrolled")` — no voiceprint has been enrolled yet.
///   - `.denied(reason: "below threshold")`   — cosine similarity < threshold.
///   - `.admitted`                             — cosine similarity ≥ threshold.
///
/// **Audited bypass mode**
///   - `.bypassed` is returned for every verify call.
///   - `.bypassed` is NOT `.admitted` — callers must log and audit it.
///   - This is an explicit, named operator decision, not a silent fixture stub.
final class OwnerGate: @unchecked Sendable {

    // MARK: - Nested types

    enum Mode: Equatable, Sendable {
        /// Real speaker verification required. Fails closed on empty or unmatched embeddings.
        case enforce
        /// Explicit audited operator escape hatch. Returns `.bypassed` (never `.admitted`) so
        /// callers can surface bypasses in the audit chain. NOT a silent fixture stub.
        case auditedBypass
    }

    enum Decision: Equatable, Sendable {
        /// Voiceprint matched — cosine similarity ≥ threshold.
        case admitted
        /// Verification failed. `reason` is one of: "empty embedding" / "no owner enrolled" /
        /// "below threshold".
        case denied(reason: String)
        /// auditedBypass mode active — operator has explicitly overridden verification.
        /// Distinguishable from `.admitted`; callers MUST log this.
        case bypassed
    }

    // MARK: - Properties

    private let mode: Mode
    private let threshold: Double
    private let lock = NSLock()
    private var enrolled: [Float]?

    // MARK: - Init

    init(mode: Mode = .enforce, threshold: Double = 0.75) {
        self.mode = mode
        self.threshold = threshold
    }

    // MARK: - Enrollment

    /// Enroll the owner voiceprint. Empty embeddings are silently rejected — enrolling `[]`
    /// is a no-op that leaves `isEnrolled` false. Returns `true` on success, `false` if rejected.
    @discardableResult
    func enroll(_ embedding: [Float]) -> Bool {
        guard !embedding.isEmpty else { return false }
        lock.withLock { enrolled = embedding }
        return true
    }

    /// `true` once a non-empty voiceprint has been successfully enrolled.
    var isEnrolled: Bool {
        lock.withLock { enrolled != nil }
    }

    // MARK: - Verification

    /// Evaluate a candidate embedding against the enrolled voiceprint.
    ///
    /// In `auditedBypass` mode, always returns `.bypassed` — callers must audit it.
    /// In `enforce` mode, fails closed: empty → denied, not enrolled → denied, low score → denied.
    func verify(_ embedding: [Float]) -> Decision {
        // auditedBypass: return .bypassed for every call regardless of embedding or enrollment.
        // This is NOT silent admission — callers must log the bypass in the audit chain.
        if mode == .auditedBypass { return .bypassed }

        // enforce — FAIL CLOSED
        guard !embedding.isEmpty else {
            return .denied(reason: "empty embedding")
        }
        guard let stored = lock.withLock({ enrolled }) else {
            return .denied(reason: "no owner enrolled")
        }
        let score = cosineSimilarity(stored, embedding)
        return score >= threshold ? .admitted : .denied(reason: "below threshold")
    }
}
