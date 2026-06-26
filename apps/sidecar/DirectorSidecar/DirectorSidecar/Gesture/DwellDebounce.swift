//
//  DwellDebounce.swift
//  DirectorSidecar
//
//  Port of packages/gesture/src/confidence/dwell.ts — the dwell + debounce guard that defeats
//  the "Midas touch" problem: a referent must stay above threshold continuously for `dwellMs`
//  before it fires, with hysteresis (enter > exit) to stop boundary flicker and a cooldown to
//  block double-fire. Pure: dt is passed in (ms), no clock read. Stateful, so a class.
//

import Foundation

struct DwellDebounceParams: Equatable, Sendable {
    /// Confidence must reach `enter` to engage the dwell...
    let enter: Double
    /// ...and stay above `exit` (lower) to remain engaged. enter > exit.
    let exit: Double
    /// Continuous engaged time required before firing.
    let dwellMs: Double
    /// Refractory window after a fire during which it cannot fire again.
    let cooldownMs: Double
}

struct DwellResult: Equatable, Sendable {
    /// Currently engaged (above the hysteresis band) — surface for the clarification /
    /// manual-fallback UI when confidence is low (not engaged).
    let active: Bool
    /// True on the single update where the dwell completes; false otherwise.
    let fired: Bool
}

final class DwellDebounce {
    private let params: DwellDebounceParams
    private var engaged = false
    private var dwell: Double = 0
    private var cooldown: Double = 0
    private var firedThisEngagement = false

    init(_ params: DwellDebounceParams) {
        self.params = params
    }

    func update(_ confidence: Double, _ dtMs: Double) -> DwellResult {
        if cooldown > 0 { cooldown = max(0, cooldown - dtMs) }

        // Hysteresis: enter the band at `enter`, leave only below `exit`.
        if !engaged && confidence >= params.enter {
            engaged = true
            dwell = 0
            firedThisEngagement = false
        } else if engaged && confidence < params.exit {
            engaged = false
            dwell = 0
            firedThisEngagement = false
        }

        var fired = false
        if engaged {
            dwell += dtMs
            if dwell >= params.dwellMs && !firedThisEngagement && cooldown == 0 {
                fired = true
                firedThisEngagement = true
                cooldown = params.cooldownMs
            }
        }

        return DwellResult(active: engaged, fired: fired)
    }
}
