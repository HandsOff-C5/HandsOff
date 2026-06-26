//
//  TemporalBinderTests.swift
//  DirectorSidecarTests
//
//  The temporal deixis binder (TemporalBinder). Ports packages/intent/src/binding/temporal-binder.test.ts
//  so the Swift binder routes each deictic word to the surface pointed at WHILE it was spoken,
//  identically to the original: gesture-precedes-speech tolerance, hand-over-head modality
//  precedence, the point→window (frontmost) fallback when a hand candidate's targetId isn't a
//  pointable window, and unbound-not-misbound when nothing brackets the word.
//

import Testing
import Foundation
@testable import DirectorSidecar

// MARK: - Builders

private func bounds(_ x: Double, _ y: Double, _ width: Double, _ height: Double) -> CuaWindowBounds {
    CuaWindowBounds(x: x, y: y, width: width, height: height)
}

private func window(_ id: String, _ bounds: CuaWindowBounds, zIndex: Int = 0) -> CuaWindow {
    CuaWindow(
        id: id, title: id, app: id, pid: 42, windowId: 7,
        availability: .available, accessStatus: .accessible, focused: false,
        bounds: bounds, zIndex: zIndex)
}

// Two surfaces side by side: Notes on the left, Slack on the right. The binder must route the first
// deictic to one and the second to the other based on WHEN each word was spoken.
private let windows: [CuaWindow] = [
    window("win-notes", bounds(0, 0, 400, 400)),
    window("win-slack", bounds(1000, 0, 400, 400)),
]

private func word(_ text: String, _ startMs: Double, _ endMs: Double) -> Contracts.TranscriptWord {
    Contracts.TranscriptWord(text: text, startMs: startMs, endMs: endMs, confidence: 0.9)
}

private func handAt(
    _ tsMs: Double,
    _ targetId: String,
    phase: Contracts.GestureState = .locked,
    confidence: Double = 0.85
) -> HandTraceSample {
    let candidate = Contracts.PointingCandidate(
        targetId: targetId, confidence: confidence, calibrationQuality: .good)
    // The point is incidental for hand samples (the candidate already resolves the surface); put it
    // inside the target window for realism.
    let x: Double = targetId == "win-notes" ? 200 : 1200
    return HandTraceSample(x: x, y: 200, candidate: candidate, phase: phase, tsMs: tsMs)
}

private func headAt(_ tsMs: Double, _ x: Double, confidence: Double = 0.8) -> HeadTraceSample {
    HeadTraceSample(x: x, y: 200, confidence: confidence, tsMs: tsMs)
}

// MARK: - isDeicticWord

struct TemporalBinderDeicticVocabTests {
    @Test func matchesTheDeicticVocabularyCaseAndPunctuationInsensitively() {
        #expect(TemporalBinder.isDeicticWord("this"))
        #expect(TemporalBinder.isDeicticWord("This,"))
        #expect(TemporalBinder.isDeicticWord("THAT"))
        #expect(TemporalBinder.isDeicticWord("these"))
        #expect(TemporalBinder.isDeicticWord("those"))
        #expect(TemporalBinder.isDeicticWord("here"))
        #expect(TemporalBinder.isDeicticWord("there."))
    }

    @Test func rejectsNonDeicticWords() {
        #expect(!TemporalBinder.isDeicticWord("type"))
        #expect(!TemporalBinder.isDeicticWord("Laura"))
        #expect(!TemporalBinder.isDeicticWord("the"))
    }
}

// MARK: - Multi-target (the Notes/Slack case) — temporal-binder.test.ts:75-98

struct TemporalBinderMultiTargetTests {
    @Test func bindsTwoDeicticWordsAtDifferentTimesToTwoDifferentSurfaces() {
        // "type Laura in THIS [@1000] and hello in THAT [@5000]"
        let words = [
            word("type", 100, 300),
            word("Laura", 300, 600),
            word("in", 600, 800),
            word("this", 1000, 1300),
            word("and", 3000, 3200),
            word("hello", 3200, 3600),
            word("in", 3600, 3800),
            word("that", 5000, 5300),
        ]
        let handTrace = [handAt(1100, "win-notes"), handAt(5100, "win-slack")]

        let bindings = TemporalBinder.bind(
            words: words, headTrace: [], handTrace: handTrace, windows: windows)

        #expect(bindings.count == 2)
        #expect(bindings[0].word == "this")
        #expect(bindings[0].evidence?.surface?.id == "win-notes")
        #expect(bindings[1].word == "that")
        #expect(bindings[1].evidence?.surface?.id == "win-slack")
        // The two referents are distinct surfaces.
        #expect(bindings[0].evidence?.surface?.id != bindings[1].evidence?.surface?.id)
    }

    @Test func stampsTheStrategyWithTheBoundWordAndTheSampleTimestamp() {
        let words = [word("this", 1000, 1300)]
        let handTrace = [handAt(1100, "win-notes")]
        let bindings = TemporalBinder.bind(
            words: words, headTrace: [], handTrace: handTrace, windows: windows)
        #expect(bindings[0].evidence?.source == .fusion)
        #expect(bindings[0].evidence?.strategy == "temporal-bind:this@1100")
    }
}

// MARK: - Gesture-precedes-speech tolerance

struct TemporalBinderToleranceTests {
    @Test func bindsAGesture800msBeforeTheWord() {
        let words = [word("this", 2000, 2300)]
        // The only hand sample fired at 1200 — 800ms before the word starts.
        let handTrace = [handAt(1200, "win-notes")]
        let bindings = TemporalBinder.bind(
            words: words, headTrace: [], handTrace: handTrace, windows: windows)
        #expect(bindings[0].evidence?.surface?.id == "win-notes")
    }

    @Test func doesNotBindAGestureFarOutsideTheToleranceWindow() {
        let words = [word("this", 5000, 5300)]
        // Gesture at 1000 — 4s before the word, well beyond the 1.5s default tolerance.
        let handTrace = [handAt(1000, "win-notes")]
        let bindings = TemporalBinder.bind(
            words: words, headTrace: [], handTrace: handTrace, windows: windows)
        #expect(bindings[0].evidence == nil)
    }

    @Test func doesNotBindAGestureThatLandsAfterTheWordEnds() {
        let words = [word("this", 1000, 1300)]
        // Gesture at 2000 — after the word ended; speech-precedes-gesture is not allowed.
        let handTrace = [handAt(2000, "win-notes")]
        let bindings = TemporalBinder.bind(
            words: words, headTrace: [], handTrace: handTrace, windows: windows)
        #expect(bindings[0].evidence == nil)
    }

    @Test func honorsACustomTolerance() {
        let words = [word("this", 2000, 2300)]
        let handTrace = [handAt(1200, "win-notes")]  // 800ms before
        let tight = TemporalBinder.bind(
            words: words, headTrace: [], handTrace: handTrace, windows: windows, toleranceMs: 500)
        #expect(tight[0].evidence == nil)
    }
}

// MARK: - Unbound, not mis-bound

struct TemporalBinderUnboundTests {
    @Test func leavesADeicticWordWithNoNearbySampleUnbound() {
        let words = [word("type", 100, 300), word("this", 1000, 1300)]
        let bindings = TemporalBinder.bind(
            words: words, headTrace: [], handTrace: [], windows: windows)
        #expect(bindings.count == 1)
        #expect(bindings[0].word == "this")
        #expect(bindings[0].evidence == nil)
    }

    @Test func bindsTheWordWithASampleAndLeavesTheOneWithoutUnbound() {
        let words = [word("this", 1000, 1300), word("that", 5000, 5300)]
        // Only the first word has a bracketing hand sample.
        let handTrace = [handAt(1100, "win-notes")]
        let bindings = TemporalBinder.bind(
            words: words, headTrace: [], handTrace: handTrace, windows: windows)
        #expect(bindings[0].evidence?.surface?.id == "win-notes")
        #expect(bindings[1].evidence == nil)
    }

    @Test func bindsToTheWindowUnderTheHandPointWhenTargetIdDoesNotMatchAWindow() {
        let words = [word("this", 1000, 1300)]
        // The gesture lane resolved a DISPLAY id ("display-1") that isn't a pointable window, but the
        // hand point sits inside Slack → bind to that real window via the point→window fallback
        // instead of dropping the hand signal.
        let handTrace = [
            HandTraceSample(
                x: 1200, y: 200,
                candidate: Contracts.PointingCandidate(
                    targetId: "display-1", confidence: 0.85, calibrationQuality: .good),
                phase: .locked, tsMs: 1100)
        ]
        let bindings = TemporalBinder.bind(
            words: words, headTrace: [], handTrace: handTrace, windows: windows)
        #expect(bindings[0].evidence?.surface?.id == "win-slack")
        // Confidence is the hand's own (the primary modality), not a head-rank score.
        #expect(bindings[0].evidence?.confidence == 0.85)
    }

    @Test func leavesUnboundWhenTargetIdUnknownAndPointOutsideEveryWindow() {
        let words = [word("this", 1000, 1300)]
        // Unknown targetId and the point is far from any window (beyond the ranker's neighborhood) →
        // no window to fall back to → unbound, not mis-bound.
        let handTrace = [
            HandTraceSample(
                x: 5000, y: 5000,
                candidate: Contracts.PointingCandidate(
                    targetId: "display-1", confidence: 0.85, calibrationQuality: .good),
                phase: .locked, tsMs: 1100)
        ]
        let bindings = TemporalBinder.bind(
            words: words, headTrace: [], handTrace: handTrace, windows: windows)
        #expect(bindings[0].evidence == nil)
    }
}

// MARK: - Single deictic / single target (back-compat)

struct TemporalBinderSingleTargetTests {
    @Test func producesExactlyOneReferent() {
        let words = [word("click", 100, 400), word("this", 1000, 1300)]
        let handTrace = [handAt(1100, "win-notes")]
        let bindings = TemporalBinder.bind(
            words: words, headTrace: [], handTrace: handTrace, windows: windows)
        #expect(bindings.count == 1)
        #expect(bindings[0].evidence?.surface?.id == "win-notes")
        #expect(bindings[0].evidence?.confidence == 0.85)
    }
}

// MARK: - Modality precedence

struct TemporalBinderModalityTests {
    @Test func prefersALockedHandReferentOverAHeadPointAtTheSameInstant() {
        let words = [word("this", 1000, 1300)]
        // Hand locked on Notes; head aimed at Slack — hand wins.
        let handTrace = [handAt(1100, "win-notes", phase: .locked)]
        let headTrace = [headAt(1100, 1200)]  // x=1200 sits inside Slack's bounds
        let bindings = TemporalBinder.bind(
            words: words, headTrace: headTrace, handTrace: handTrace, windows: windows)
        #expect(bindings[0].evidence?.surface?.id == "win-notes")
    }

    @Test func prefersALockedHandSampleOverANonLockedOneInTheSameWindow() {
        let words = [word("this", 1000, 1300)]
        let handTrace = [
            handAt(1050, "win-slack", phase: .candidate, confidence: 0.95),  // cursor, higher conf, earlier
            handAt(1150, "win-notes", phase: .locked, confidence: 0.6),  // locked, lower confidence
        ]
        let bindings = TemporalBinder.bind(
            words: words, headTrace: [], handTrace: handTrace, windows: windows)
        // Locked beats cursor even though the cursor sample has higher confidence.
        #expect(bindings[0].evidence?.surface?.id == "win-notes")
    }

    @Test func fallsBackToTheHeadPointWhenNoHandSampleBracketsTheWord() {
        let words = [word("this", 1000, 1300)]
        // No hand sample; head aimed inside Notes (x=200).
        let headTrace = [headAt(1100, 200)]
        let bindings = TemporalBinder.bind(
            words: words, headTrace: headTrace, handTrace: [], windows: windows)
        #expect(bindings[0].evidence?.surface?.id == "win-notes")
        // Head confidence comes from the ranker's score (point inside bounds → 1).
        #expect(bindings[0].evidence?.confidence == 1)
    }

    @Test func ignoresAHandSampleWithNoCandidateAndUsesTheHeadInstead() {
        let words = [word("this", 1000, 1300)]
        let handTrace = [
            HandTraceSample(x: 200, y: 200, candidate: nil, phase: .idle, tsMs: 1100)
        ]
        let headTrace = [headAt(1100, 1200)]  // inside Slack
        let bindings = TemporalBinder.bind(
            words: words, headTrace: headTrace, handTrace: handTrace, windows: windows)
        #expect(bindings[0].evidence?.surface?.id == "win-slack")
    }
}

// MARK: - point→window picks the frontmost overlapping window

struct TemporalBinderFrontmostTests {
    // Two windows over the SAME region; `front` is frontmost (higher zIndex).
    private let overlapping: [CuaWindow] = [
        window("win-back", bounds(0, 0, 500, 500), zIndex: 1),
        window("win-front", bounds(0, 0, 500, 500), zIndex: 9),
    ]

    @Test func bindsTheHandPointToTheFrontmostWindowWhenTwoWindowsOverlapIt() {
        let words = [word("here", 1000, 1300)]
        // targetId doesn't match → resolves by point; both windows contain (250,250), so the
        // frontmost (front) must win.
        let handTrace = [
            HandTraceSample(
                x: 250, y: 250,
                candidate: Contracts.PointingCandidate(
                    targetId: "display-1", confidence: 0.85, calibrationQuality: .good),
                phase: .locked, tsMs: 1100)
        ]
        let bindings = TemporalBinder.bind(
            words: words, headTrace: [], handTrace: handTrace, windows: overlapping)
        #expect(bindings[0].evidence?.surface?.id == "win-front")
    }

    @Test func bindsTheHeadPointToTheFrontmostOverlappingWindowToo() {
        let words = [word("here", 1000, 1300)]
        let headTrace = [headAt(1100, 250)]  // x=250,y=200 inside both windows
        let bindings = TemporalBinder.bind(
            words: words, headTrace: headTrace, handTrace: [], windows: overlapping)
        #expect(bindings[0].evidence?.surface?.id == "win-front")
    }
}
