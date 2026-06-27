//
//  NativeAXActuationTests.swift
//  DirectorSidecarTests
//
//  #148 — headless tests for the in-process native AX actuation slice. The live AX path needs TCC
//  Accessibility + real windows, so it is on-device manual (like the camera path); these exercise the
//  PURE parts: the driver-call decode, the hybrid AX-vs-driver routing decision, the verify/rollback
//  decision, the hybrid driver's fallback wiring, and that mutating verbs stay BEHIND the gate.
//
//  The native-attempt cases use requests that can NEVER resolve a native element (missing pid /
//  element / point, or a non-existent pid), so `NativeAXActuation.perform` returns nil regardless of
//  whether the test host happens to hold an Accessibility grant — the fallback is deterministic.
//

import Testing
import Foundation
@testable import DirectorSidecar

// MARK: - Fake driver

/// Records every call and returns scripted results, so the hybrid driver's fallback routing is
/// observable. An actor → Sendable, satisfying `CuaLoopDriver`'s async requirements.
private actor FakeLoopDriver: CuaLoopDriver {
    private(set) var calledTools: [String] = []
    private(set) var getWindowStateCalls = 0
    private(set) var listWindowsCalls = 0
    let scriptedWindows: [CuaWindow]

    init(scriptedWindows: [CuaWindow] = []) { self.scriptedWindows = scriptedWindows }

    func listWindows() async -> CuaResult<[CuaWindow]> {
        listWindowsCalls += 1
        return .succeeded(scriptedWindows)
    }
    func getWindowState(pid: Int, windowId: Int) async -> CuaResult<CuaWindowState> {
        getWindowStateCalls += 1
        return .failed(error: "driver-getstate")
    }
    func listTools() async -> CuaResult<[DriverToolDefinition]> { .succeeded([]) }
    func call(tool: String, input: JSONValue) async -> CuaResult<JSONValue> {
        calledTools.append(tool)
        return .succeeded(.string("driver-ok"))
    }
}

private func window(pid: Int, windowId: Int) -> CuaWindow {
    CuaWindow(
        id: String(windowId), title: "T", app: "App", pid: pid, windowId: windowId,
        availability: .available, accessStatus: .accessible, focused: true,
        bounds: CuaWindowBounds(x: 0, y: 0, width: 100, height: 100), zIndex: 1)
}

// MARK: - Decode

@Test func decodeClickByElementIndex() {
    let req = NativeActionRequest.decode(
        tool: "click", input: .object(["pid": .number(123), "window_id": .number(7), "element_index": .number(3)]))
    #expect(req?.kind == .click)
    #expect(req?.pid == 123)
    #expect(req?.windowId == 7)
    #expect(req?.elementIndex == 3)
    #expect(req?.point == nil)
}

@Test func decodeClickByPoint() {
    let req = NativeActionRequest.decode(tool: "click", input: .object(["x": .number(12), "y": .number(34)]))
    #expect(req?.point == CGPoint(x: 12, y: 34))
}

@Test func decodeTypeAndSetValueText() {
    let typed = NativeActionRequest.decode(tool: "type_text", input: .object(["text": .string("hi")]))
    #expect(typed?.kind == .typeText)
    #expect(typed?.text == "hi")
    let set = NativeActionRequest.decode(tool: "set_value", input: .object(["value": .string("v")]))
    #expect(set?.kind == .setValue)
    #expect(set?.value == "v")
}

@Test func decodeRejectsNonNativeTool() {
    #expect(NativeActionRequest.decode(tool: "launch_app", input: .object(["app_name": .string("X")])) == nil)
    #expect(NativeActionRequest.decode(tool: "get_window_state", input: .object([:])) == nil)
}

// MARK: - Route policy

@Test func routeResolvedGoesNativeOpaqueGoesDriver() {
    #expect(NativeActionPolicy.route(resolution: .resolved) == .nativeAX)
    #expect(NativeActionPolicy.route(resolution: .unresolvedOpaque) == .driverFallback)
}

// MARK: - Verify policy

@Test func verifySetValueExactMatch() {
    #expect(NativeActionPolicy.verifySetValue(readBack: "hello", expected: "hello") == .verified)
    #expect(NativeActionPolicy.verifySetValue(readBack: "hel", expected: "hello") == .mismatchRollback)
    #expect(NativeActionPolicy.verifySetValue(readBack: nil, expected: "hello") == .mismatchRollback)
}

@Test func verifyTypedRequiresObservableChange() {
    #expect(NativeActionPolicy.verifyTyped(prior: "", readBack: "abc", typed: "abc") == .verified)
    #expect(NativeActionPolicy.verifyTyped(prior: "x", readBack: "xabc", typed: "abc") == .verified)
    // Unchanged field (keystrokes never landed) → rollback → driver fallback.
    #expect(NativeActionPolicy.verifyTyped(prior: "x", readBack: "x", typed: "abc") == .mismatchRollback)
    #expect(NativeActionPolicy.verifyTyped(prior: "x", readBack: nil, typed: "abc") == .mismatchRollback)
}

// MARK: - Hybrid driver routing

@Test func nonNativeToolPassesThroughToDriver() async {
    let fake = FakeLoopDriver()
    let hybrid = HybridActionDriver(driver: fake, nativeWindows: { [] })
    let result = await hybrid.call(tool: "launch_app", input: .object(["app_name": .string("X")]))
    if case let .succeeded(value) = result { #expect(value == .string("driver-ok")) } else { Issue.record("expected success") }
    #expect(await fake.calledTools == ["launch_app"])
}

@Test func unresolvableNativeVerbFallsBackToDriver() async {
    let fake = FakeLoopDriver()
    let hybrid = HybridActionDriver(driver: fake, nativeWindows: { [] })
    // No pid / element / point → native resolution is impossible → driver fallback (deterministic).
    _ = await hybrid.call(tool: "click", input: .object([:]))
    _ = await hybrid.call(tool: "type_text", input: .object([:]))
    _ = await hybrid.call(tool: "set_value", input: .object([:]))
    #expect(await fake.calledTools == ["click", "type_text", "set_value"])
}

@Test func listWindowsPrefersNativeThenFallsBack() async {
    let native = [window(pid: 10, windowId: 1)]
    let withNative = HybridActionDriver(driver: FakeLoopDriver(), nativeWindows: { native })
    if case let .succeeded(windows) = await withNative.listWindows() {
        #expect(windows == native)
    } else { Issue.record("expected native windows") }

    let fake = FakeLoopDriver(scriptedWindows: [window(pid: 20, windowId: 2)])
    let emptyNative = HybridActionDriver(driver: fake, nativeWindows: { [] })
    _ = await emptyNative.listWindows()
    #expect(await fake.listWindowsCalls == 1)  // empty native → driver fallback.
}

@Test func getWindowStateFallsBackWhenNativeReadEmpty() async {
    // A non-existent pid yields no AX app → no in-process elements → driver fallback (deterministic).
    let fake = FakeLoopDriver()
    let hybrid = HybridActionDriver(driver: fake, nativeWindows: { [window(pid: 999_999, windowId: 1)] })
    let result = await hybrid.getWindowState(pid: 999_999, windowId: 1)
    if case .failed = result {} else { Issue.record("expected driver fallback failure") }
    #expect(await fake.getWindowStateCalls == 1)
}

// MARK: - The AX backend sits BEHIND the gate

@Test func mutatingClickIsGatedBeforeDispatch() {
    // A click with no element metadata cannot be proven non-committing → gated (KD3 safe default).
    // The hybrid AX backend only ever runs AFTER this gate passes (VoiceCuaLoop.firstBlockedStep
    // → ToolCallGate, upstream of driver.call), so an unapproved mutating click never reaches it.
    let unapproved = ToolCallGate.gate(tool: .click, target: nil, approved: false)
    #expect(unapproved.blockedResult != nil)
    let approved = ToolCallGate.gate(tool: .click, target: nil, approved: true)
    #expect(approved.isAllowed)
}
