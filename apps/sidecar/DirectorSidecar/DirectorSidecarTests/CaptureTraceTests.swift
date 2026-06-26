//
//  CaptureTraceTests.swift
//  DirectorSidecarTests
//
//  The capture-trace recorder (CaptureTraceRecorder). Ports
//  apps/desktop/src/features/capture-trace/createCaptureTrace.test.tsx so the Swift recorder windows
//  the head/hand/word streams to [start, stop], orders them by time, and — the load-bearing part —
//  normalizes the monotonic hand-frame clock onto the epoch clock pinned at start, identically to
//  the original.
//

import Testing
import Foundation
@testable import DirectorSidecar

// Two independent, controllable clocks: `now` is the epoch clock (head + word stamps), `perf` is the
// monotonic frame clock the hand stream uses. They are deliberately offset so the normalization math
// is observable.
private final class FakeClock {
    var nowMs: Double = 1_000_000  // epoch ms
    var perfMs: Double = 5_000  // monotonic ms (arbitrary origin)

    var clocks: CaptureTraceClocks {
        CaptureTraceClocks(now: { self.nowMs }, performanceNow: { self.perfMs })
    }
}

private let candidate = Contracts.PointingCandidate(
    targetId: "win-notes", confidence: 0.8, calibrationQuality: .good)

private let words: [Contracts.TranscriptWord] = [
    Contracts.TranscriptWord(text: "type", startMs: 1_000_100, endMs: 1_000_300, confidence: 0.9),
    Contracts.TranscriptWord(text: "this", startMs: 1_000_400, endMs: 1_000_700, confidence: 0.8),
]

// MARK: - Lifecycle

struct CaptureTraceLifecycleTests {
    @Test func notRecordingUntilStartAndStopReturnsNilWhenNeverStarted() {
        let recorder = CaptureTraceRecorder(clocks: FakeClock().clocks)
        #expect(recorder.recording == false)
        #expect(recorder.stop() == nil)
    }

    @Test func reportsRecordingBetweenStartAndStop() {
        let recorder = CaptureTraceRecorder(clocks: FakeClock().clocks)
        recorder.start()
        #expect(recorder.recording == true)
        _ = recorder.stop()
        #expect(recorder.recording == false)
    }

    @Test func ignoresSamplesRecordedWhileNoWindowIsOpen() {
        let recorder = CaptureTraceRecorder(clocks: FakeClock().clocks)
        recorder.recordHead(HeadPointInput(x: 1, y: 2, confidence: 1, tsMs: 1_000_001))
        recorder.recordHand(
            HandSampleInput(frameTimestampMs: 5_001, x: 3, y: 4, candidate: nil, phase: .idle))
        recorder.start()
        let trace = recorder.stop()
        #expect(trace?.headTrace == [])
        #expect(trace?.handTrace == [])
    }
}

// MARK: - Windowing

struct CaptureTraceWindowingTests {
    @Test func retainsHeadHandWordSamplesWithinTheWindowInTimeOrder() {
        let c = FakeClock()
        let recorder = CaptureTraceRecorder(clocks: c.clocks)
        // start at epoch 1_000_000 / perf 5_000.
        recorder.start()

        // Head samples (epoch ms) arrive out of order; the trace sorts them.
        recorder.recordHead(HeadPointInput(x: 10, y: 10, confidence: 0.7, tsMs: 1_000_500))
        recorder.recordHead(HeadPointInput(x: 20, y: 20, confidence: 0.9, tsMs: 1_000_200))

        // Hand samples (perf ms): perf 5_100 and 5_300 → epoch 1_000_100 / 1_000_300.
        recorder.recordHand(
            HandSampleInput(frameTimestampMs: 5_300, x: 3, y: 3, candidate: candidate, phase: .locked))
        recorder.recordHand(
            HandSampleInput(frameTimestampMs: 5_100, x: 1, y: 1, candidate: nil, phase: .idle))

        recorder.setWords(words)

        // stop after all samples (epoch 1_001_000).
        c.nowMs = 1_001_000
        let trace = recorder.stop()

        #expect(trace?.headTrace.map(\.tsMs) == [1_000_200, 1_000_500])
        #expect(trace?.handTrace.map(\.tsMs) == [1_000_100, 1_000_300])
        #expect(trace?.words == words)
    }

    @Test func excludesHeadSamplesWhoseEpochStampFallsOutsideTheWindow() {
        let c = FakeClock()
        let recorder = CaptureTraceRecorder(clocks: c.clocks)
        recorder.start()  // epoch 1_000_000

        recorder.recordHead(HeadPointInput(x: 0, y: 0, confidence: 1, tsMs: 999_999))  // before start
        recorder.recordHead(HeadPointInput(x: 1, y: 1, confidence: 1, tsMs: 1_000_500))  // inside
        recorder.recordHead(HeadPointInput(x: 2, y: 2, confidence: 1, tsMs: 1_002_000))  // after stop

        c.nowMs = 1_001_000  // stop boundary
        let trace = recorder.stop()
        #expect(trace?.headTrace.map(\.tsMs) == [1_000_500])
    }

    @Test func excludesAHandFrameWhoseNormalizedStampLandsAfterTheWindowCloses() {
        let c = FakeClock()
        let recorder = CaptureTraceRecorder(clocks: c.clocks)
        recorder.start()  // epoch 1_000_000 / perf 5_000

        recorder.recordHand(
            HandSampleInput(frameTimestampMs: 5_400, x: 1, y: 1, candidate: nil, phase: .idle))  // → 1_000_400, inside
        recorder.recordHand(
            HandSampleInput(frameTimestampMs: 6_000, x: 2, y: 2, candidate: nil, phase: .idle))  // → 1_001_000, outside

        c.nowMs = 1_000_500  // stop boundary < second sample's normalized stamp
        let trace = recorder.stop()
        #expect(trace?.handTrace.map(\.tsMs) == [1_000_400])
    }
}

// MARK: - Clock normalization

struct CaptureTraceClockNormalizationTests {
    @Test func mapsAHandFramePerfStampToEpochMsViaTheStartOffset() {
        let c = FakeClock()
        let recorder = CaptureTraceRecorder(clocks: c.clocks)
        recorder.start()  // epoch 1_000_000 pinned to perf 5_000

        // A frame 250ms into the window: perf 5_250 → epoch 1_000_000 + (5_250 - 5_000).
        recorder.recordHand(
            HandSampleInput(frameTimestampMs: 5_250, x: 9, y: 9, candidate: candidate, phase: .candidate))

        c.nowMs = 1_001_000
        let trace = recorder.stop()
        #expect(trace?.handTrace.first?.tsMs == 1_000_250)
        // The screen point + candidate + phase survive unchanged.
        let sample = trace?.handTrace.first
        #expect(sample?.x == 9)
        #expect(sample?.y == 9)
        #expect(sample?.candidate == candidate)
        #expect(sample?.phase == .candidate)
    }

    @Test func usesTheOffsetCapturedAtThisStartNotAStaleOne() {
        let c = FakeClock()
        let recorder = CaptureTraceRecorder(clocks: c.clocks)

        recorder.start()
        _ = recorder.stop()

        // Second window starts at a different epoch/perf pair.
        c.nowMs = 2_000_000
        c.perfMs = 8_000
        recorder.start()
        recorder.recordHand(
            HandSampleInput(frameTimestampMs: 8_100, x: 0, y: 0, candidate: nil, phase: .idle))
        c.nowMs = 2_001_000
        let trace = recorder.stop()
        // perf 8_100 → epoch 2_000_000 + 100.
        #expect(trace?.handTrace.first?.tsMs == 2_000_100)
    }
}

// MARK: - Edge cases

struct CaptureTraceEdgeCaseTests {
    @Test func returnsAnEmptyHandTraceWhenNoHandSampleWasRecorded() {
        let c = FakeClock()
        let recorder = CaptureTraceRecorder(clocks: c.clocks)
        recorder.start()
        recorder.recordHead(HeadPointInput(x: 1, y: 1, confidence: 1, tsMs: 1_000_100))
        c.nowMs = 1_001_000
        let trace = recorder.stop()
        #expect(trace?.handTrace == [])
        #expect(trace?.headTrace.count == 1)
    }

    @Test func closesTheWindowCleanlyWhenToggledOffMidUtterance() {
        let c = FakeClock()
        let recorder = CaptureTraceRecorder(clocks: c.clocks)
        recorder.start()
        recorder.recordHand(
            HandSampleInput(frameTimestampMs: 5_100, x: 1, y: 1, candidate: candidate, phase: .locked))
        // No setWords — utterance never finalized.
        c.nowMs = 1_000_500
        let trace = recorder.stop()
        #expect(trace?.words == [])
        #expect(trace?.handTrace.count == 1)
        #expect(recorder.recording == false)
    }

    @Test func aFreshStartDiscardsThePriorWindowsBuffers() {
        let c = FakeClock()
        let recorder = CaptureTraceRecorder(clocks: c.clocks)
        recorder.start()
        recorder.recordHead(HeadPointInput(x: 1, y: 1, confidence: 1, tsMs: 1_000_100))
        // Re-arm without stop: the earlier head sample must not leak into the new trace.
        c.nowMs = 1_002_000
        c.perfMs = 7_000
        recorder.start()
        c.nowMs = 1_003_000
        let trace = recorder.stop()
        #expect(trace?.headTrace == [])
    }
}
