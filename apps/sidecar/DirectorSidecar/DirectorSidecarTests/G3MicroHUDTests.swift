//
//  G3MicroHUDTests.swift
//  DirectorSidecarTests
//
//  G3 micro-HUD logic: the phase-derivation matrix (the three triggers + yield-to-full + hide on
//  disconnect), edge geometry, and frame application (agent row, audio-level proxy).
//

import Testing
import Foundation
import CoreGraphics
@testable import DirectorSidecar

// MARK: phase derivation matrix

@Test func derivesAmbientIdleWhenListeningNoAgents() {
    #expect(MicroHUDModel.derivePhase(connected: true, listening: true, fullHUDActive: false, cursorAtEdge: false, agentRunning: false) == .ambientIdle)
}

@Test func derivesAmbientActiveWhenListeningWithAgents() {
    #expect(MicroHUDModel.derivePhase(connected: true, listening: true, fullHUDActive: false, cursorAtEdge: false, agentRunning: true) == .ambientActive)
}

@Test func yieldsToFullHUDWhenContentArrives() {
    #expect(MicroHUDModel.derivePhase(connected: true, listening: true, fullHUDActive: true, cursorAtEdge: false, agentRunning: false) == .hidden)
}

@Test func derivesAgentWorkingWhenNotListeningButAgentRuns() {
    #expect(MicroHUDModel.derivePhase(connected: true, listening: false, fullHUDActive: false, cursorAtEdge: false, agentRunning: true) == .agentWorking)
}

@Test func derivesEdgeHoverRevealWhenIdleCursorAtEdge() {
    #expect(MicroHUDModel.derivePhase(connected: true, listening: false, fullHUDActive: false, cursorAtEdge: true, agentRunning: false) == .edgeHoverReveal)
}

@Test func hiddenWhenDisconnected() {
    // Never a broken pill — disconnect always hides, even mid-listening.
    #expect(MicroHUDModel.derivePhase(connected: false, listening: true, fullHUDActive: false, cursorAtEdge: true, agentRunning: true) == .hidden)
}

@Test func hiddenWhenIdleAndCursorAway() {
    #expect(MicroHUDModel.derivePhase(connected: true, listening: false, fullHUDActive: false, cursorAtEdge: false, agentRunning: false) == .hidden)
}

// MARK: edge geometry

@Test func isAtEdgeDetectsTrailingAndLeading() {
    let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
    #expect(MicroHUDModel.isAtEdge(cursor: CGPoint(x: 1439, y: 450), screen: screen, edge: .trailing))
    #expect(!MicroHUDModel.isAtEdge(cursor: CGPoint(x: 1000, y: 450), screen: screen, edge: .trailing))
    #expect(MicroHUDModel.isAtEdge(cursor: CGPoint(x: 1, y: 450), screen: screen, edge: .leading))
    #expect(!MicroHUDModel.isAtEdge(cursor: CGPoint(x: 50, y: 450), screen: screen, edge: .leading))
}

@Test func isAtEdgeRejectsOffScreenY() {
    let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
    #expect(!MicroHUDModel.isAtEdge(cursor: CGPoint(x: 1439, y: 2000), screen: screen, edge: .trailing))
}

// MARK: frame application (main actor)

@MainActor
@Test func listeningShowsAmbientAndTranscriptBumpsAudio() {
    let model = MicroHUDModel(listenEdge: .trailing)
    #expect(model.phase == .hidden)
    model.setListening(true)
    #expect(model.phase == .ambientIdle)
    model.apply(.transcript(TranscriptEvent(kind: "partial", text: "x", confidence: 0.9, latencyMs: 1, receivedAt: 0)))
    #expect(model.audioLevel > 0.5)
}

@MainActor
@Test func sessionsDriveAgentRowAndWorkingState() {
    let model = MicroHUDModel(listenEdge: .trailing)
    let payload = SessionsPayload(sessions: [
        SupervisionSession(id: "a", status: .running, startedAt: "t", updatedAt: "t", finishedAt: nil, title: "A", agentLabel: "Claude Code"),
    ], counts: nil)
    model.apply(.sessions(payload))
    // Not listening, an agent runs → agentWorking with the row populated.
    #expect(model.runningSessions.count == 1)
    #expect(model.phase == .agentWorking)
}

@MainActor
@Test func fullHUDActiveHidesMicro() {
    let model = MicroHUDModel(listenEdge: .trailing)
    model.setListening(true)
    #expect(model.isVisible)
    model.setFullHUDActive(true)
    #expect(model.phase == .hidden)
}
