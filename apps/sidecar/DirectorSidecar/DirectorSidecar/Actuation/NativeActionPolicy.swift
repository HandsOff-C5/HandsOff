//
//  NativeActionPolicy.swift
//  DirectorSidecar
//
//  #148 — the pure routing + verify decisions for the hybrid AX/driver dispatch, split out from the
//  live AX so they are unit-tested headlessly. Two policies:
//
//   • ROUTE (AX-first, driver-fallback): a mutating verb whose element resolves to a real NATIVE AX
//     element actuates in-process; an AX-opaque surface (Electron like Slack, canvas/WebGL) or an
//     unresolved element / no Accessibility trust falls back to the `cua-driver`. Native AX is the
//     DEFAULT; the driver is the fallback — mirroring the window-source discipline (NativeWindowSource
//     first, driver only when the native list is empty).
//   • VERIFY (read-back, port of ActionActuator's verify→rollback): after a value mutation the field
//     is re-read; a mismatch rolls back the captured prior value and the call is treated as NOT
//     verified (so the hybrid router surfaces a failure rather than faking success).
//

import Foundation

/// Whether a mutating request resolved to a real native AX element. The live layer computes this
/// (it folds in `AXIsProcessTrusted()` + the element lookup); the router decides from it.
enum ElementResolution: Equatable, Sendable {
    /// A real native AX element was found (point→element or element_index) → actuate in-process.
    case resolved
    /// AX-opaque surface, element not found, or no Accessibility trust → fall back to the driver.
    case unresolvedOpaque
}

/// Where a decoded native request is dispatched.
enum NativeRoute: Equatable, Sendable {
    /// In-process native AX actuation using the Director's own TCC grant.
    case nativeAX
    /// The external `cua-driver` (AX-opaque surfaces and the no-trust path).
    case driverFallback
}

/// The post-mutation read-back decision (INV-3 spirit: verify or roll back, never silent).
enum VerifyDecision: Equatable, Sendable {
    case verified
    case mismatchRollback
}

/// Pure policy functions — the headless-testable core of the hybrid dispatch.
enum NativeActionPolicy {

    /// AX-first routing: actuate natively only for a resolved native element; everything else
    /// (opaque/unresolved/untrusted) is the driver fallback.
    static func route(resolution: ElementResolution) -> NativeRoute {
        switch resolution {
        case .resolved: return .nativeAX
        case .unresolvedOpaque: return .driverFallback
        }
    }

    /// `set_value` read-back: the post-mutation `kAXValue` must EQUAL what we set. (The 6pt frame
    /// tolerance the rebuild backend used is geometry-only; a text value compares exactly.)
    static func verifySetValue(readBack: String?, expected: String) -> VerifyDecision {
        readBack == expected ? .verified : .mismatchRollback
    }

    /// `type_text` read-back: the typed text must be observable in the focused field — the value
    /// CHANGED from the prior contents AND now contains what we typed. A field that did not change
    /// (the keystrokes never landed) is a mismatch, so the router surfaces a failure.
    static func verifyTyped(prior: String?, readBack: String?, typed: String) -> VerifyDecision {
        guard let readBack else { return .mismatchRollback }
        if readBack != (prior ?? "") && readBack.contains(typed) { return .verified }
        return .mismatchRollback
    }
}
