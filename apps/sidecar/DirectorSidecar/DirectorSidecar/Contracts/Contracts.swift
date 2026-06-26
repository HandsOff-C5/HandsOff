//
//  Contracts.swift
//  DirectorSidecar
//
//  Faithful Swift ports of the @handsoff/contracts TypeScript schemas (the
//  "contracts-first" step of ADR 0005 / PORTING.md § Porting Order 1). These are
//  the canonical, full-shape models the native engine decodes — distinct from the
//  decode-only *lite* UI mirrors in Bridge/LoopTypes.swift and Bridge/SessionTypes.swift,
//  which carry only the subset the HUD renders.
//
//  Everything here is namespaced under `Contracts.` so the full ports coexist with
//  the top-level lite types (`SurfaceSnapshot`, `SelectedReferent`, `SupervisionSession`,
//  `ResolvedIntentLite`, …) during the migration without a name collision. The shared
//  contract enums `RiskLevel` and `ExecutionStatus` stay top-level (the UI already
//  binds them) and are referenced from here as the single source of truth.
//
//  Drift guard: each type has a JSON fixture decode test in DirectorSidecarTests that
//  feeds real TypeScript-shaped payloads. An enum case added/renamed or a field shape
//  changed TS-side fails those tests loudly rather than silently mis-decoding.
//

import Foundation

/// Namespace for the faithful @handsoff/contracts ports. Caseless `enum` so it can
/// never be instantiated; types attach via `extension Contracts`.
enum Contracts {}
