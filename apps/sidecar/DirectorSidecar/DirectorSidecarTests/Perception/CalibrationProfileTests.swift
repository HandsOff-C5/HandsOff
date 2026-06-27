import Foundation
import Testing
@testable import DirectorSidecar

// SL-2b — per-display calibration profile persistence (FR-24). Restored persistence-only (the 9-dot
// capture FLOW is not ported, so the source's `CaptureFlow`-based reconnect test is omitted). A
// profile is keyed by the STABLE display UUID, not the transient `CGDirectDisplayID`; persistence is
// injected (`InMemoryProfileStore`) so the test never touches real UserDefaults.

@Test func testProfileKeyedByUUIDNotDisplayID() {
    // Two displays with DIFFERENT UUIDs keep DIFFERENT profiles; resolving by a UUID returns only
    // that UUID's profile (the key is the UUID — a transient ID never enters the store).
    let store = InMemoryProfileStore()
    let repo = CalibrationProfileRepository(store: store)
    let a = CalibrationProfile(
        affine: Affine(a: 1, b: 0, c: 0, d: 0, e: 1, f: 0), residualPx: 5, band: .good)
    let b = CalibrationProfile(
        affine: Affine(a: 2, b: 0, c: 0, d: 0, e: 2, f: 0), residualPx: 55, band: .fair)
    repo.save(a, forDisplayUUID: "UUID-A")
    repo.save(b, forDisplayUUID: "UUID-B")

    #expect(repo.load(forDisplayUUID: "UUID-A") == a)
    #expect(repo.load(forDisplayUUID: "UUID-B") == b)
    #expect(repo.load(forDisplayUUID: "UUID-UNKNOWN") == nil)
    #expect(a != b)
}

@Test func testAffineAndHomographyProfilesRoundTrip() throws {
    // The profile snapshot survives a JSON round-trip for every transform family.
    let store = InMemoryProfileStore()
    let repo = CalibrationProfileRepository(store: store)

    let aff = Affine(a: 1.5, b: 0.1, c: -3, d: 0.2, e: 2.5, f: 7)
    repo.save(CalibrationProfile(affine: aff, residualPx: 12, band: .good), forDisplayUUID: "AFF")
    let homo = PerceptionHomography(entries: [1, 0, 0, 0, 1, 0, 0, 0, 1])
    repo.save(
        CalibrationProfile(homography: homo, residualPx: 40, band: .fair), forDisplayUUID: "HOMO")

    let rAff = try #require(repo.load(forDisplayUUID: "AFF")?.affineTransform())
    #expect(rAff == aff)
    let rHomo = try #require(repo.load(forDisplayUUID: "HOMO")?.homographyTransform())
    #expect(rHomo == homo)
}

@Test func testRidgePolyProfileReconstructsCalibrationFit() throws {
    // The RB-3 path: persist a unified `CalibrationFit.ridgePoly` (the hand-fingertip→screen map),
    // reload it, reconstruct the `CalibrationFit`, and assert it reproduces the original prediction.
    let store = InMemoryProfileStore()
    let repo = CalibrationProfileRepository(store: store)
    let fit = CalibrationFit.ridgePoly(thetaX: [0.1, 0.2, 0.3, 0.4, 0.5, 0.6],
                                       thetaY: [0.6, 0.5, 0.4, 0.3, 0.2, 0.1], lambda: 0.01)
    repo.save(CalibrationProfile(fit: fit, residualPx: 8, band: .good), forDisplayUUID: "RIDGE")

    let profile = try #require(repo.load(forDisplayUUID: "RIDGE"))
    #expect(profile.kind == .ridgePoly)
    let restored = try #require(profile.calibrationFit())
    let f = SIMD2<Double>(0.3, 0.7)
    #expect(restored.apply(f) == fit.apply(f), "reconstructed fit reproduces the original map")
}

@Test func testRemoveProfile() {
    let store = InMemoryProfileStore()
    let repo = CalibrationProfileRepository(store: store)
    repo.save(
        CalibrationProfile(affine: Affine(a: 1, b: 0, c: 0, d: 0, e: 1, f: 0),
                           residualPx: 1, band: .good),
        forDisplayUUID: "X")
    #expect(repo.load(forDisplayUUID: "X") != nil)
    repo.remove(forDisplayUUID: "X")
    #expect(repo.load(forDisplayUUID: "X") == nil)
}

@Test func testResidualBandClassify() {
    #expect(ResidualBand.classify(rmsPx: 10) == .good)   // ≤ 20
    #expect(ResidualBand.classify(rmsPx: 20) == .good)
    #expect(ResidualBand.classify(rmsPx: 40) == .fair)   // ≤ 60
    #expect(ResidualBand.classify(rmsPx: 80) == .poor)
    #expect(ResidualBand.semantic == .fitResidual, "I10 — a fit-residual band, never an accuracy claim")
}
