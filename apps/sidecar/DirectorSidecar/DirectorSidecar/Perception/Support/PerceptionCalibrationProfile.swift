import Foundation

#if canImport(CoreGraphics)
import CoreGraphics
#endif

// SL-2b — per-display calibration PROFILE + persistence (FR-24).
//
// Restored from the handsoff-rebuild `Models/Calibration/CalibrationProfile.swift` (trimmed in the
// Phase-1 port). PERSISTENCE-ONLY: the per-display fitted transform is saved/loaded so the RB-3 hand
// pointer can reconstruct a `CalibrationFit` and feed `HandModelPlugin.calibration`. The 9-dot CAPTURE
// FLOW (CaptureFlow/CaptureSequencer/CalibrationModelPlugin) is NOT ported here — it needs a UI to
// drive and can't be exercised headlessly — so the two `CaptureFlow.{displayFit,modelFit}` convenience
// initializers are omitted; profiles are built from a `CalibrationFit` (+ residual) directly.
//
// A calibration is fitted PER DISPLAY (each monitor's eye/face→screen map is its own polynomial).
// Display IDs (`CGDirectDisplayID`) are NOT stable — they change on reconnect, reorder, or sleep/wake
// — so a profile is keyed by the STABLE per-display UUID (`DisplayMap.displayUUIDString`).
// Persistence is INJECTABLE (`ProfileStore`) so tests never touch real `UserDefaults`.
//
// Renamed vs the source for this single-module target: `Homography` → `PerceptionHomography`.

// MARK: - Residual band

/// What a `ResidualBand` measures. Pinned to `.fitResidual` so a "good" band is never mistaken for an
/// accuracy guarantee (I10).
public enum ResidualSemantic {
    case fitResidual
    case accuracy
}

/// Quality band for a fit residual (RMS reprojection error, screen px): good ≤ `goodPx`, fair ≤
/// `fairPx`, else poor. I10 — a FIT-residual band, NOT accuracy. Thresholds default to the salvaged
/// `Params.calib` values (good 20px / fair 60px).
public enum ResidualBand: Equatable {
    case good
    case fair
    case poor

    /// I10 — this is a fit-residual band, NOT an accuracy band.
    public static let semantic: ResidualSemantic = .fitResidual

    public static let defaultGoodPx: Double = 20
    public static let defaultFairPx: Double = 60

    public static func classify(
        rmsPx: Double,
        goodPx: Double = ResidualBand.defaultGoodPx,
        fairPx: Double = ResidualBand.defaultFairPx
    ) -> ResidualBand {
        if rmsPx <= goodPx { return .good }
        if rmsPx <= fairPx { return .fair }
        return .poor
    }
}

// MARK: - Persisted snapshot

/// A persisted, `Codable` calibration result for one display: the fitted transform plus its
/// fit-residual (I10 — residual is a FIT target, not accuracy). The `kind` says which transform
/// family was fitted; the matching coefficient set is stored so the exact map is restored on reload.
public struct CalibrationProfile: Codable, Equatable {

    /// Which transform family this profile holds.
    public enum Kind: String, Codable, Equatable {
        case affine
        case homography
        /// The salvaged MULTI-feature eye-gaze map (`PolynomialTransform`, no-cross-term basis).
        case polynomial
        /// The unified 2D `CalibrationFit.ridgePoly` (standard 6-coeff cross-term basis + λ) — the
        /// hand-fingertip / face-noseOffset → normalized-screen map (RB-1b). Reconstructed via
        /// `calibrationFit()` for the RB-3 hand/face consumers.
        case ridgePoly
    }

    public let kind: Kind

    /// Affine coeffs `[a,b,c,d,e,f]` (when `kind == .affine`).
    public let affine: [Double]?
    /// Homography row-major entries (length 9; when `kind == .homography`).
    public let homography: [Double]?
    /// Polynomial per-axis coeffs over φ (when `kind == .polynomial`): `featureCount`, `cx`, `cy`.
    public let featureCount: Int?
    public let polyCX: [Double]?
    public let polyCY: [Double]?
    /// Unified ridge-poly per-axis coeffs over `{1, xe, ye, xe·ye, xe², ye²}` plus the λ they were
    /// fit with (when `kind == .ridgePoly`). This is the `CalibrationFit.ridgePoly` payload.
    public let thetaX: [Double]?
    public let thetaY: [Double]?
    public let lambda: Double?

    /// The fit residual (RMS reprojection error, screen px) and its band (`FR-23`, I10).
    public let residualPx: Double
    public let band: Band

    /// Persisted residual band (mirrors `ResidualBand`; I10 fit-residual, not accuracy).
    public enum Band: String, Codable, Equatable {
        case good
        case fair
        case poor

        public init(_ b: ResidualBand) {
            switch b {
            case .good: self = .good
            case .fair: self = .fair
            case .poor: self = .poor
            }
        }

        public var residualBand: ResidualBand {
            switch self {
            case .good: return .good
            case .fair: return .fair
            case .poor: return .poor
            }
        }
    }

    // MARK: Builders from the live fit types

    /// The single designated initializer; the typed builders below delegate to it so every field is
    /// set exactly once (the unused coefficient slots stay `nil`).
    private init(
        kind: Kind,
        affine: [Double]? = nil,
        homography: [Double]? = nil,
        featureCount: Int? = nil,
        polyCX: [Double]? = nil,
        polyCY: [Double]? = nil,
        thetaX: [Double]? = nil,
        thetaY: [Double]? = nil,
        lambda: Double? = nil,
        residualPx: Double,
        band: ResidualBand
    ) {
        self.kind = kind
        self.affine = affine
        self.homography = homography
        self.featureCount = featureCount
        self.polyCX = polyCX
        self.polyCY = polyCY
        self.thetaX = thetaX
        self.thetaY = thetaY
        self.lambda = lambda
        self.residualPx = residualPx
        self.band = Band(band)
    }

    public init(affine: Affine, residualPx: Double, band: ResidualBand) {
        self.init(
            kind: .affine,
            affine: [affine.a, affine.b, affine.c, affine.d, affine.e, affine.f],
            residualPx: residualPx, band: band)
    }

    public init(homography: PerceptionHomography, residualPx: Double, band: ResidualBand) {
        self.init(
            kind: .homography, homography: homography.entries, residualPx: residualPx, band: band)
    }

    public init(polynomial: PolynomialTransform, residualPx: Double, band: ResidualBand) {
        self.init(
            kind: .polynomial, featureCount: polynomial.featureCount,
            polyCX: polynomial.cx, polyCY: polynomial.cy, residualPx: residualPx, band: band)
    }

    /// Build from any unified 2D `CalibrationFit` (affine / homography / ridgePoly) plus its graded
    /// residual. This is the RB-1b path: a fitted `CalibrationFit` is persisted here so RB-3 can
    /// reconstruct it via `calibrationFit()`.
    public init(fit: CalibrationFit, residualPx: Double, band: ResidualBand) {
        switch fit {
        case .affine(let a):
            self.init(affine: a, residualPx: residualPx, band: band)
        case .homography(let h):
            self.init(homography: h, residualPx: residualPx, band: band)
        case .ridgePoly(let tx, let ty, let lambda):
            self.init(
                kind: .ridgePoly, thetaX: tx, thetaY: ty, lambda: lambda,
                residualPx: residualPx, band: band)
        }
    }

    // MARK: Reconstruct the live transform

    /// Rebuild the salvaged eye-gaze polynomial transform (when this profile holds one). Returns
    /// `nil` for a non-polynomial profile.
    public func polynomialTransform() -> PolynomialTransform? {
        guard kind == .polynomial, let fc = featureCount, let cx = polyCX, let cy = polyCY
        else { return nil }
        return PolynomialTransform(featureCount: fc, cx: cx, cy: cy)
    }

    /// Rebuild the unified 2D `CalibrationFit` (the hand/face screen map) from whichever family this
    /// profile stores — affine, homography, or ridgePoly. Returns `nil` only for the multi-feature
    /// eye-gaze `.polynomial` profile (which is not a 2D `CalibrationFit`). This is the reconstructor
    /// the RB-3 hand/face consumers read.
    public func calibrationFit() -> CalibrationFit? {
        switch kind {
        case .affine:
            return affineTransform().map { .affine($0) }
        case .homography:
            return homographyTransform().map { .homography($0) }
        case .ridgePoly:
            guard let tx = thetaX, let ty = thetaY, let l = lambda else { return nil }
            return .ridgePoly(thetaX: tx, thetaY: ty, lambda: l)
        case .polynomial:
            return nil
        }
    }

    /// Rebuild the affine transform (when this profile holds one).
    public func affineTransform() -> Affine? {
        guard kind == .affine, let a = affine, a.count == 6 else { return nil }
        return Affine(a: a[0], b: a[1], c: a[2], d: a[3], e: a[4], f: a[5])
    }

    /// Rebuild the homography (when this profile holds one).
    public func homographyTransform() -> PerceptionHomography? {
        guard kind == .homography, let h = homography, h.count == 9 else { return nil }
        return PerceptionHomography(entries: h)
    }

    /// The persisted residual band as the live `ResidualBand`.
    public var residualBand: ResidualBand { band.residualBand }
}

// MARK: - Injectable persistence

/// A profile key→value store. The default backs onto `UserDefaults`; tests inject an in-memory store
/// so they never touch real defaults / Application Support.
public protocol ProfileStore: AnyObject {
    func data(forKey key: String) -> Data?
    func set(_ data: Data?, forKey key: String)
}

/// In-memory store (the test injection — also handy for a transient session).
public final class InMemoryProfileStore: ProfileStore {
    private var backing: [String: Data] = [:]
    public init() {}
    public func data(forKey key: String) -> Data? { backing[key] }
    public func set(_ data: Data?, forKey key: String) {
        if let data { backing[key] = data } else { backing[key] = nil }
    }
}

/// `UserDefaults`-backed store (the live default). A dedicated suite name keeps the calibration
/// profiles out of the app's general defaults namespace.
public final class UserDefaultsProfileStore: ProfileStore {
    private let defaults: UserDefaults
    public init(suiteName: String = "com.handsoff.calibration") {
        self.defaults = UserDefaults(suiteName: suiteName) ?? .standard
    }
    public func data(forKey key: String) -> Data? { defaults.data(forKey: key) }
    public func set(_ data: Data?, forKey key: String) {
        if let data { defaults.set(data, forKey: key) } else { defaults.removeObject(forKey: key) }
    }
}

// MARK: - The per-display profile repository (UUID-keyed, FR-24)

/// Stores and retrieves a `CalibrationProfile` per display, keyed by the STABLE display UUID
/// (`FR-24`). The repository never holds a `CGDirectDisplayID` — callers resolve the live ID to a
/// UUID string (via `DisplayMap.displayUUIDString`) at the boundary, then save/load by UUID. Because
/// the UUID is the key, a profile written while a monitor is connected is recovered unchanged after
/// that monitor is disconnected and reconnected (its ID may differ; its UUID does not).
public final class CalibrationProfileRepository {

    private let store: ProfileStore
    private let keyPrefix: String
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(store: ProfileStore = UserDefaultsProfileStore(),
                keyPrefix: String = "calibration.profile.") {
        self.store = store
        self.keyPrefix = keyPrefix
    }

    private func key(_ uuid: String) -> String { keyPrefix + uuid }

    /// Persist `profile` for the display identified by `displayUUID`.
    public func save(_ profile: CalibrationProfile, forDisplayUUID displayUUID: String) {
        guard let data = try? encoder.encode(profile) else { return }
        store.set(data, forKey: key(displayUUID))
    }

    /// Load the profile for the display identified by `displayUUID`, or `nil` if none stored.
    public func load(forDisplayUUID displayUUID: String) -> CalibrationProfile? {
        guard let data = store.data(forKey: key(displayUUID)) else { return nil }
        return try? decoder.decode(CalibrationProfile.self, from: data)
    }

    /// Remove any profile for the display.
    public func remove(forDisplayUUID displayUUID: String) {
        store.set(nil, forKey: key(displayUUID))
    }

    #if canImport(CoreGraphics)
    /// Resolve a LIVE `CGDirectDisplayID` to its stable UUID and load its profile. The ID→UUID hop is
    /// exactly what survives a reconnect (the ID is transient; the UUID is not). Returns `nil` if the
    /// ID can't be resolved to a UUID or no profile is stored.
    public func load(forDisplayID displayID: CGDirectDisplayID) -> CalibrationProfile? {
        guard let uuid = DisplayMap.displayUUIDString(for: displayID) else { return nil }
        return load(forDisplayUUID: uuid)
    }

    /// Resolve a LIVE `CGDirectDisplayID` to its stable UUID and persist its profile.
    public func save(_ profile: CalibrationProfile, forDisplayID displayID: CGDirectDisplayID) {
        guard let uuid = DisplayMap.displayUUIDString(for: displayID) else { return }
        save(profile, forDisplayUUID: uuid)
    }
    #endif
}
