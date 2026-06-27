//
//  HeadPointingIntakeTests.swift
//  DirectorSidecarTests
//
//  The head-pointing intake — the migration step that makes head/face tracking reach the intent.
//  Covers the shared `HeadPointSnapshot` holder, the pure `HeadPointingFusion.build` (the head branch
//  of buildPointingEvidence.ts), and the `HeadPointingIntake` end-to-end through a real `VoiceCuaLoop`
//  + a recording resolver — proving a tracked head point lands on the resolver's tick-0 input as
//  `head` pointing evidence + ranked candidate surfaces (not just the overlay cursor). A real camera
//  can't run under headless xcodebuild, so the head point is injected through the snapshot seam.
//

import Testing
import Foundation
@testable import DirectorSidecar

// MARK: - Builders & fakes

private func bounds(_ x: Double, _ y: Double, _ width: Double, _ height: Double) -> CuaWindowBounds {
    CuaWindowBounds(x: x, y: y, width: width, height: height)
}

private func window(
    _ id: String,
    _ bounds: CuaWindowBounds?,
    focused: Bool = false,
    app: String = "Codex"
) -> CuaWindow {
    CuaWindow(
        id: id, title: id, app: app, pid: 42, windowId: 7,
        availability: .available, accessStatus: .accessible, focused: focused,
        bounds: bounds, zIndex: 0)
}

private func head(_ x: Double, _ y: Double) -> HeadPoint {
    HeadPoint(x: x, y: y, yaw: nil, pitch: nil, confidence: 0.9, ts: 1)
}

/// A locked gesture referent: the `toGestureEvidence` surface-bearing evidence (source `.gesture`)
/// the live `ReferentLoop` consumer records into the snapshot, optionally with a wrist-ray cursor.
private func gestureReferent(
    surfaceId: String,
    confidence: Double = 0.85,
    cursor: Contracts.PointingEvidence.Cursor? = nil
) -> GestureReferent {
    let evidence = Contracts.PointingEvidence(
        source: .gesture, confidence: confidence, strategy: "wrist-ray-calibrated:good",
        surface: Contracts.SurfaceSnapshot(
            id: surfaceId, title: surfaceId, app: "Display", pid: nil, windowId: nil,
            availability: .available, accessStatus: .accessible),
        cursor: nil)
    return GestureReferent(evidence: evidence, cursor: cursor)
}

private func gestureSnapshot(_ referent: GestureReferent) -> GestureSnapshot {
    let snapshot = GestureSnapshot()
    snapshot.record(referent)
    return snapshot
}

private func finalTranscript(_ text: String) -> Contracts.FinalTranscript {
    let json = #"{"kind":"final","text":"\#(text)","confidence":0.95,"latencyMs":100,"receivedAt":1}"#
    // swiftlint:disable:next force_try
    return try! JSONDecoder().decode(Contracts.FinalTranscript.self, from: Data(json.utf8))
}

/// A scripted CUA driver: `listWindows` returns the supplied windows (the geometry the intake ranks
/// the head point against AND the loop's per-tick observation), every other read is inert.
private actor FakeIntakeDriver: CuaLoopDriver {
    let windows: [CuaWindow]
    init(windows: [CuaWindow]) { self.windows = windows }

    func listWindows() -> CuaResult<[CuaWindow]> { .succeeded(windows) }
    func getWindowState(pid: Int, windowId: Int) -> CuaResult<CuaWindowState> { .failed(error: "no state") }
    func screenshot(pid: Int, windowId: Int) -> CuaResult<CuaScreenshot> { .failed(error: "no screenshot") }
    func listTools() -> CuaResult<[DriverToolDefinition]> { .succeeded([]) }
    func call(tool: String, input: JSONValue) -> CuaResult<JSONValue> { .succeeded(.object([:])) }
}

/// Records every input the loop hands the resolver, then ends the goal with `done` so the run settles
/// after tick 0 — letting a test read exactly what pointing evidence reached the resolver.
private actor RecordingResolver {
    private(set) var inputs: [Contracts.IntentInput] = []

    func resolve(_ input: Contracts.IntentInput, _ createdAt: String) -> Contracts.ResolvedIntent {
        inputs.append(input)
        return NextToolCallResolver.nextToolCallToIntent(
            NextToolCall(status: .done, tool: nil, args: nil, rationale: "done", summary: "ok", reason: nil),
            input: input, id: "intent-done", createdAt: createdAt)
    }

    func seen() -> [Contracts.IntentInput] { inputs }
}

// MARK: - Snapshot

struct HeadPointSnapshotTests {
    @Test func startsEmptyAndHoldsTheLatestPoint() {
        let snapshot = HeadPointSnapshot()
        #expect(snapshot.current == nil)

        snapshot.record(head(10, 20))
        snapshot.record(head(30, 40))   // latest-wins
        #expect(snapshot.current == head(30, 40))

        // Not cleared between reads — the point captured during an utterance survives until the loop
        // reads it ~1.5s later, after the camera has stopped on push-to-talk release.
        #expect(snapshot.current == head(30, 40))
    }
}

// MARK: - Pure fusion (the head branch of buildPointingEvidence)

struct HeadPointingFusionTests {
    @Test func emitsFaceTrackerCursorAndRankedNeighborhood() {
        let built = HeadPointingFusion.build(
            head: head(150, 150),
            windows: [
                window("looked-at", bounds(100, 100, 200, 200)),   // point is inside → score 1
                window("far", bounds(1000, 1000, 50, 50)),         // outside the radius → dropped
            ])

        // The positional face-tracker cue (fixed 0.5 confidence, head cursor, no surface).
        let faceTracker = built.pointingEvidence.first { $0.strategy == "face-tracker-position" }
        #expect(faceTracker?.source == .head)
        #expect(faceTracker?.confidence == 0.5)
        #expect(faceTracker?.cursor == Contracts.PointingEvidence.Cursor(x: 150, y: 150))
        #expect(faceTracker?.surface == nil)

        // The looked-at window as head-neighborhood evidence carrying its closeness as confidence.
        let neighborhood = built.pointingEvidence.first { $0.strategy == "head-neighborhood" }
        #expect(neighborhood?.source == .head)
        #expect(neighborhood?.surface?.id == "looked-at")
        #expect(neighborhood?.confidence == 1)
        #expect(neighborhood?.cursor == Contracts.PointingEvidence.Cursor(x: 150, y: 150))

        // The far window is dropped; only the looked-at surface is a candidate.
        #expect(built.surfaceCandidates.map(\.id) == ["looked-at"])
        #expect(!built.pointingEvidence.contains { $0.strategy == "head-neighborhood-empty" })
    }

    @Test func emitsHeadNeighborhoodEmptyWhenNothingIsNear() {
        let built = HeadPointingFusion.build(
            head: head(0, 0),
            windows: [window("far", bounds(1000, 1000, 50, 50))])

        #expect(built.pointingEvidence.contains { $0.strategy == "face-tracker-position" })
        let empty = built.pointingEvidence.first { $0.strategy == "head-neighborhood-empty" }
        #expect(empty?.source == .head)
        #expect(empty?.confidence == 0)
        #expect(empty?.cursor == Contracts.PointingEvidence.Cursor(x: 0, y: 0))
        #expect(built.surfaceCandidates.isEmpty)   // no surface-bearing evidence
    }

    @Test func fallsBackToActiveWindowWhenNoHeadPoint() {
        let built = HeadPointingFusion.build(
            head: nil,
            windows: [window("bg", bounds(0, 0, 10, 10)), window("active", bounds(0, 0, 100, 100), focused: true)])

        #expect(built.pointingEvidence.count == 1)
        let fallback = built.pointingEvidence.first
        #expect(fallback?.source == .cursor)
        #expect(fallback?.strategy == "active-window-current-cursor")
        #expect(fallback?.surface?.id == "active")     // the focused window, not the first
        #expect(built.surfaceCandidates.map(\.id) == ["active"])
    }

    @Test func emitsNothingWithNoHeadAndNoWindows() {
        let built = HeadPointingFusion.build(head: nil, windows: [])
        #expect(built.pointingEvidence.isEmpty)
        #expect(built.surfaceCandidates.isEmpty)
    }

    // MARK: gesture branch (buildPointingEvidence lines 83-96)

    @Test func lockedGestureReferentLeadsAndWinsTheDedup() {
        // A locked hand referent on "pointed-at" + a head point looking at "looked-at": both surfaces
        // are candidates, but the gesture referent LEADS the evidence so its surface wins first place.
        let built = HeadPointingFusion.build(
            head: head(150, 150),
            windows: [window("looked-at", bounds(100, 100, 200, 200))],
            gesture: gestureReferent(surfaceId: "pointed-at"))

        let gesture = built.pointingEvidence.first { $0.source == .gesture }
        #expect(gesture?.surface?.id == "pointed-at")
        #expect(gesture?.strategy == "wrist-ray-calibrated:good")
        // The gesture surface leads; the head's looked-at window follows.
        #expect(built.surfaceCandidates.map(\.id) == ["pointed-at", "looked-at"])
        // Head evidence still present — combinative, not a hierarchy.
        #expect(built.pointingEvidence.contains { $0.strategy == "head-neighborhood" && $0.surface?.id == "looked-at" })
    }

    @Test func gestureCursorWithoutALockEmitsWristRayPosition() {
        // A hand present but not locked: the wrist-ray cursor enters as its own 0.3-confidence
        // positional cue, with no surface, exactly like the desktop's gestureCursor push.
        let built = HeadPointingFusion.build(
            head: nil,
            windows: [],
            gesture: GestureReferent(cursor: Contracts.PointingEvidence.Cursor(x: 0.6, y: 0.4)))

        #expect(built.pointingEvidence.count == 1)
        let cursorCue = built.pointingEvidence.first
        #expect(cursorCue?.source == .gesture)
        #expect(cursorCue?.strategy == "wrist-ray-position")
        #expect(cursorCue?.confidence == 0.3)
        #expect(cursorCue?.surface == nil)
        #expect(cursorCue?.cursor == Contracts.PointingEvidence.Cursor(x: 0.6, y: 0.4))
        #expect(built.surfaceCandidates.isEmpty)
    }

    @Test func lockedReferentCarriesItsConfidenceToTheCursorEntry() {
        // With a lock AND a cursor, both entries are emitted; the cursor entry borrows the lock's
        // confidence (desktop: `confidence: gesture ? gesture.confidence : 0.3`) since the locked
        // evidence carries no cursor of its own.
        let built = HeadPointingFusion.build(
            head: nil,
            windows: [],
            gesture: gestureReferent(
                surfaceId: "pointed-at", confidence: 0.91,
                cursor: Contracts.PointingEvidence.Cursor(x: 320, y: 240)))

        let locked = built.pointingEvidence.first { $0.surface?.id == "pointed-at" }
        #expect(locked?.confidence == 0.91)
        let cursorCue = built.pointingEvidence.first { $0.strategy == "wrist-ray-position" }
        #expect(cursorCue?.confidence == 0.91)
        #expect(cursorCue?.cursor == Contracts.PointingEvidence.Cursor(x: 320, y: 240))
    }

    @Test func emptyGestureFallsThroughToTheActiveWindow() {
        // An empty gesture referent contributes nothing; with no head either, the active-window
        // fallback still fires — the combined-evidence emptiness check, not head-only.
        let built = HeadPointingFusion.build(
            head: nil,
            windows: [window("active", bounds(0, 0, 100, 100), focused: true)],
            gesture: GestureReferent())

        #expect(built.pointingEvidence.count == 1)
        #expect(built.pointingEvidence.first?.strategy == "active-window-current-cursor")
        #expect(built.surfaceCandidates.map(\.id) == ["active"])
    }
}

// MARK: - Intake + end-to-end through the loop

struct HeadPointingIntakeTests {
    @Test func makeInputReadsSnapshotAndDriverGeometry() async {
        let driver = FakeIntakeDriver(windows: [window("looked-at", bounds(100, 100, 200, 200))])
        let snapshot = HeadPointSnapshot()
        snapshot.record(head(150, 150))
        let intake = HeadPointingIntake(snapshot: snapshot, driver: driver)

        let input = await intake.makeInput(for: finalTranscript("click that"), sessionId: "s1")

        #expect(input.sessionId == "s1")
        #expect(input.pointingEvidence.contains { $0.source == .head && $0.strategy == "face-tracker-position" })
        #expect(input.pointingEvidence.contains { $0.strategy == "head-neighborhood" && $0.surface?.id == "looked-at" })
        #expect(input.surfaceCandidates.map(\.id) == ["looked-at"])
    }

    // U9: the pointed selection reaches the input, read from the binder-resolved surface's pid — and
    // the fused referent stays byte-for-byte unchanged (R5: fusion still decides the surface, the
    // selection is purely additive). The reader is injected (a live AX tree can't run headless); it
    // echoes the pid it was handed so the test proves the read is keyed to the bound surface (pid 42).
    @Test func makeInputAttachesPointedSelectionWithoutPerturbingTheBoundReferent() async {
        let driver = FakeIntakeDriver(windows: [window("looked-at", bounds(100, 100, 200, 200))])
        let snapshot = HeadPointSnapshot()
        snapshot.record(head(150, 150))

        let withSelection = HeadPointingIntake(
            snapshot: snapshot, driver: driver,
            readSelection: { pid in "selection-from-pid-\(pid)" })
        let withoutSelection = HeadPointingIntake(
            snapshot: snapshot, driver: driver,
            readSelection: { _ in nil })

        let attached = await withSelection.makeInput(for: finalTranscript("summarize this"), sessionId: "s1")
        let bare = await withoutSelection.makeInput(for: finalTranscript("summarize this"), sessionId: "s1")

        // The pointed selection reaches the input, keyed to the binder-resolved surface's pid (42).
        #expect(attached.selectionText == "selection-from-pid-42")
        // No selection → nil, never a crash or empty string downstream.
        #expect(bare.selectionText == nil)

        // R5 regression guard: the fused referent is identical with or without the selection read —
        // the binder stays authoritative; selection adds *the text within* the surface, nothing else.
        #expect(attached.pointingEvidence == bare.pointingEvidence)
        #expect(attached.surfaceCandidates == bare.surfaceCandidates)
        #expect(attached.surfaceCandidates.map(\.id) == ["looked-at"])
    }

    // The whole point of the migration: a tracked head point reaches the RESOLVER's input at tick 0.
    @MainActor
    @Test func headEvidenceReachesResolverInputAtTickZero() async {
        let driver = FakeIntakeDriver(windows: [window("looked-at", bounds(100, 100, 200, 200), focused: true)])
        let snapshot = HeadPointSnapshot()
        snapshot.record(head(150, 150))
        let resolver = RecordingResolver()
        let loop = VoiceCuaLoop(
            driver: driver,
            resolve: { input, createdAt, _, _ in await resolver.resolve(input, createdAt) },
            intake: HeadPointingIntake(snapshot: snapshot, driver: driver),
            now: { "2026-06-25T12:00:00.000Z" },
            targetResolveDelayMs: 0)

        await loop.handleFinalTranscript(finalTranscript("summarize that window"))

        let first = await resolver.seen().first
        #expect(first != nil)
        // The head signal the resolver saw on the first decision.
        #expect(first?.pointingEvidence.contains { $0.source == .head && $0.strategy == "face-tracker-position" } == true)
        #expect(first?.pointingEvidence.contains { $0.strategy == "head-neighborhood" && $0.surface?.id == "looked-at" } == true)
        #expect(first?.surfaceCandidates.contains { $0.id == "looked-at" } == true)
    }

    // The end of the chain: the looked-at window must reach the RESOLVER'S PROMPT, attributed to the
    // head, so the model can target it. Builds the intake's input, then the real next-tool-call
    // prompt, and asserts the candidate surface carries source "head".
    @Test func resolverPromptSurfacesLookedAtWindowAsHeadSourced() async {
        let driver = FakeIntakeDriver(windows: [window("looked-at", bounds(100, 100, 200, 200), focused: true)])
        let snapshot = HeadPointSnapshot()
        snapshot.record(head(150, 150))
        let intake = HeadPointingIntake(snapshot: snapshot, driver: driver)

        let input = await intake.makeInput(for: finalTranscript("click that"), sessionId: "s1")
        let messages = NextToolCallPrompt.buildMessages(input, tools: [])
        guard let userContent = messages.first(where: { $0.role == "user" })?.content,
              case let .text(userMessage) = userContent else {
            Issue.record("expected a text-content user turn"); return
        }

        #expect(userMessage.contains(#""id":"looked-at""#))   // the looked-at window is a candidate…
        #expect(userMessage.contains(#""source":"head""#))    // …attributed to the head cue, for the model to act on
    }

    // The gesture gap this fix closes: a locked hand referent injected through the snapshot seam
    // reaches the intake's input as `.gesture` pointing evidence carrying its surface.
    @Test func makeInputFoldsInAnInjectedGestureReferent() async {
        let driver = FakeIntakeDriver(windows: [window("looked-at", bounds(100, 100, 200, 200))])
        let intake = HeadPointingIntake(
            snapshot: HeadPointSnapshot(),
            driver: driver,
            gesture: gestureSnapshot(gestureReferent(surfaceId: "pointed-at", confidence: 0.88)))

        let input = await intake.makeInput(for: finalTranscript("click that"), sessionId: "s1")

        let gesture = input.pointingEvidence.first { $0.source == .gesture }
        #expect(gesture?.surface?.id == "pointed-at")
        #expect(gesture?.confidence == 0.88)
        #expect(input.surfaceCandidates.contains { $0.id == "pointed-at" })
    }

    // The whole point of this fix: a locked hand referent reaches the RESOLVER's input at tick 0,
    // attributed to the gesture — so "click that" while pointing targets the pointed-at surface.
    @MainActor
    @Test func gestureEvidenceReachesResolverInputAtTickZero() async {
        let driver = FakeIntakeDriver(windows: [window("active", bounds(0, 0, 100, 100), focused: true)])
        let resolver = RecordingResolver()
        let loop = VoiceCuaLoop(
            driver: driver,
            resolve: { input, createdAt, _, _ in await resolver.resolve(input, createdAt) },
            intake: HeadPointingIntake(
                snapshot: HeadPointSnapshot(), driver: driver,
                gesture: gestureSnapshot(gestureReferent(surfaceId: "pointed-at"))),
            now: { "2026-06-25T12:00:00.000Z" },
            targetResolveDelayMs: 0)

        await loop.handleFinalTranscript(finalTranscript("click that"))

        let first = await resolver.seen().first
        #expect(first?.pointingEvidence.contains { $0.source == .gesture && $0.surface?.id == "pointed-at" } == true)
        #expect(first?.surfaceCandidates.contains { $0.id == "pointed-at" } == true)
    }

    // The end of the chain: the pointed-at surface must reach the RESOLVER'S PROMPT attributed to the
    // gesture, so the model can act on the hand-pointed target.
    @Test func resolverPromptSurfacesGesturePointedWindow() async {
        let driver = FakeIntakeDriver(windows: [window("active", bounds(0, 0, 100, 100), focused: true)])
        let intake = HeadPointingIntake(
            snapshot: HeadPointSnapshot(), driver: driver,
            gesture: gestureSnapshot(gestureReferent(surfaceId: "pointed-at")))

        let input = await intake.makeInput(for: finalTranscript("click that"), sessionId: "s1")
        let messages = NextToolCallPrompt.buildMessages(input, tools: [])
        guard let userContent = messages.first(where: { $0.role == "user" })?.content,
              case let .text(userMessage) = userContent else {
            Issue.record("expected a text-content user turn"); return
        }

        #expect(userMessage.contains(#""id":"pointed-at""#))   // the pointed-at surface is a candidate…
        #expect(userMessage.contains(#""source":"gesture""#))  // …attributed to the gesture cue
    }

    // No head point yet (camera just came up / no face): the intake degrades to the active-window
    // cursor cue and the loop still runs — never blocks for want of a head signal.
    @MainActor
    @Test func runsWithoutAHeadPointViaActiveWindowFallback() async {
        let driver = FakeIntakeDriver(windows: [window("active", bounds(0, 0, 100, 100), focused: true)])
        let resolver = RecordingResolver()
        let loop = VoiceCuaLoop(
            driver: driver,
            resolve: { input, createdAt, _, _ in await resolver.resolve(input, createdAt) },
            intake: HeadPointingIntake(snapshot: HeadPointSnapshot(), driver: driver),
            now: { "2026-06-25T12:00:00.000Z" },
            targetResolveDelayMs: 0)

        await loop.handleFinalTranscript(finalTranscript("do the thing"))

        let first = await resolver.seen().first
        #expect(first?.pointingEvidence.contains { $0.source == .cursor && $0.surface?.id == "active" } == true)
        #expect(first?.pointingEvidence.contains { $0.source == .head } == false)
    }
}
