//
//  ActivationOverlayTests.swift
//  DirectorSidecarTests
//
//  Activating Director (menu "Activate Director") must bring up exactly the three ambient overlays
//  with NO scripted intention journey: the rail waveform, a deterministically-centered gaze bracket,
//  and one hugging Director cursor. These lock the gaze-seed + single-cursor contract.
//

import Testing
import Foundation
import CoreGraphics
@testable import DirectorSidecar

// MARK: gaze brackets appear via a seeded region (no real CV yet)

@MainActor
@Test func gazeSeedMakesBracketsVisibleOnActivation() {
    let gaze = GazeBracketModel()
    gaze.setActive(true, seed: GazeRegion(x: 100, y: 100, w: 200, h: 80))
    #expect(gaze.isVisible)
    #expect(gaze.phase == .tracking)
}

@MainActor
@Test func gazeWithoutSeedStaysHidden() {
    let gaze = GazeBracketModel()
    gaze.setActive(true)                  // no seed → nothing to show until a frame arrives
    #expect(!gaze.isVisible)
}

@MainActor
@Test func deactivatingClearsSeededBrackets() {
    let gaze = GazeBracketModel()
    gaze.setActive(true, seed: GazeRegion(x: 0, y: 0, w: 10, h: 10))
    gaze.setActive(false)
    #expect(!gaze.isVisible)
    #expect(gaze.phase == .hidden)
}

@Test func centeredRegionIsCentered() {
    let r = GazeBracketModel.centeredRegion(in: CGSize(width: 1000, height: 1000))
    #expect(r.w == 280)
    #expect(r.h == 120)
    #expect(r.x == 360)                   // (1000 - 280) / 2
    #expect(r.y == 440)                   // (1000 - 120) / 2
}

// MARK: exactly one hugging cursor on activation (no traveling agent cursors)

@MainActor
@Test func activationShowsExactlyOneHuggingCursor() {
    let overlay = OverlayModel()
    overlay.setActive(true)
    #expect(overlay.cursors.count == 1)
    #expect(overlay.cursors.first?.kind == .user)
    #expect(overlay.cursors.first?.state == .hugging)
}

@MainActor
@Test func deactivatingRemovesTheHuggingCursor() {
    let overlay = OverlayModel()
    overlay.setActive(true)
    overlay.setActive(false)
    #expect(overlay.cursors.isEmpty)
}
