//
//  FnHotkeyServiceTests.swift
//  DirectorSidecarTests
//
//  Pure `FnGesture` state-machine coverage, ported 1:1 from the Rust `hotkey.rs` unit tests:
//  press-hold → start/stop, double-tap → toggle, a lone tap emits nothing, an expired pending
//  tap is a fresh press (not a toggle), a hold followed by a tap never toggles, a held second
//  tap becomes a hold, spurious releases/idempotent fn-down signals are absorbed.
//

import Testing
@testable import DirectorSidecar

@Test func capturePhaseVocabularyMatchesFrontendContract() {
    #expect(CapturePhase.start.rawValue == "start")
    #expect(CapturePhase.stop.rawValue == "stop")
    #expect(CapturePhase.toggle.rawValue == "toggle")
}

@Test func pressHoldEmitsStartThenStop() {
    var g = FnGesture()
    #expect(g.onPress(now: 0) == nil)       // down
    #expect(g.onTick(now: 200) == nil)      // below threshold → still a possible tap
    #expect(g.onTick(now: 250) == .start)   // hold commits
    #expect(g.onTick(now: 1_000) == nil)    // already holding
    #expect(g.onRelease(now: 1_200) == .stop)
}

@Test func doubleTapEmitsToggle() {
    var g = FnGesture()
    #expect(g.onPress(now: 0) == nil)       // tap 1 down
    #expect(g.onRelease(now: 80) == nil)    // tap 1 up → TapPending
    #expect(g.onPress(now: 200) == nil)     // tap 2 down (within 300 ms window)
    #expect(g.onRelease(now: 280) == .toggle)
}

@Test func singleTapEmitsNothing() {
    var g = FnGesture()
    #expect(g.onPress(now: 0) == nil)
    #expect(g.onRelease(now: 80) == nil)    // pending; no second tap arrives
    #expect(g.onTick(now: 500) == nil)
    #expect(g.onTick(now: 10_000) == nil)
}

@Test func expiredPendingTapIsNotADoubleTap() {
    var g = FnGesture()
    #expect(g.onPress(now: 0) == nil)
    #expect(g.onRelease(now: 80) == nil)    // TapPending
    // A press well past the 300 ms window is a fresh first press, not a toggle.
    #expect(g.onPress(now: 500) == nil)
    #expect(g.onRelease(now: 560) == nil)   // TapPending again, still no emit
}

@Test func holdThenSeparateTapDoesNotToggle() {
    var g = FnGesture()
    #expect(g.onPress(now: 0) == nil)
    #expect(g.onTick(now: 250) == .start)
    #expect(g.onRelease(now: 400) == .stop)
    // A later quick tap is its own gesture, never a toggle.
    #expect(g.onPress(now: 500) == nil)
    #expect(g.onRelease(now: 560) == nil)
}

@Test func secondTapHeldLongBecomesHold() {
    var g = FnGesture()
    #expect(g.onPress(now: 0) == nil)
    #expect(g.onRelease(now: 80) == nil)    // TapPending
    #expect(g.onPress(now: 200) == nil)     // second tap down (SecondDown)
    // Holding the second press past the threshold flips it to a hold.
    #expect(g.onTick(now: 500) == .start)
    #expect(g.onRelease(now: 700) == .stop)
}

@Test func spuriousReleaseIsANoop() {
    var g = FnGesture()
    #expect(g.onRelease(now: 0) == nil)     // Idle
    #expect(g.onPress(now: 10) == nil)
    #expect(g.onRelease(now: 20) == nil)    // → TapPending
    #expect(g.onRelease(now: 30) == nil)    // release while TapPending: noop
}

@Test func fnBitIdempotentSignalsAreAbsorbed() {
    // Repeated press-while-down (other modifiers firing flagsChanged with the fn bit still
    // set) must not advance the machine or emit.
    var g = FnGesture()
    #expect(g.onPress(now: 0) == nil)
    #expect(g.onPress(now: 5) == nil)       // spurious
    #expect(g.onPress(now: 10) == nil)      // spurious
    #expect(g.onRelease(now: 80) == nil)
}

// MARK: phase → listening command routing (the C1 wiring decision)
// `FnGesture` was tested but the phase→command mapping the host wires into the app was not — the gap
// that let "service never instantiated" ship. These pin the routing the app depends on.

@Test func pressHoldPhasesRouteToStartAndStop() {
    // Press-hold is absolute, independent of the current listening state.
    #expect(listeningCommand(for: .start, isListening: false) == .startListening)
    #expect(listeningCommand(for: .start, isListening: true) == .startListening)
    #expect(listeningCommand(for: .stop, isListening: true) == .stopListening)
    #expect(listeningCommand(for: .stop, isListening: false) == .stopListening)
}

@Test func doubleTapToggleFlipsAgainstCurrentState() {
    #expect(listeningCommand(for: .toggle, isListening: false) == .startListening)
    #expect(listeningCommand(for: .toggle, isListening: true) == .stopListening)
}
