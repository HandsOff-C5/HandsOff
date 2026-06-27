//
//  NativeAXActuation.swift
//  DirectorSidecar
//
//  #148 — the in-process native AX action backend: the one place native click / type_text / set_value
//  side effects fire, using the Director's OWN Accessibility grant (not the `cua-driver`). It composes
//  the pure policy (route + verify) with the live `AXElementResolver`, and performs the read-back
//  verify→rollback ported from the rebuild's ActionActuator. It NEVER fakes success: a verb whose
//  element does not resolve, or whose mutation does not verify, returns a non-success outcome so the
//  hybrid driver falls back to the `cua-driver` rather than reporting a silent no-op.
//
//  This backend sits BEHIND the loop's existing ToolCallGate (every mutating step is gated/approved
//  before dispatch reaches the driver — see VoiceCuaLoop.runGoalAction → StepDispatch.firstBlockedStep),
//  so nothing here weakens approval. Live-only: verified on-device, never headless (the pure parts are).
//

import Foundation

/// The outcome of a native actuation attempt. `verified == true` means the mutation landed and the
/// read-back confirmed it (or, for a click, the element resolved and the action posted — a click has
/// no AX-readable field to compare). `verified == false` means a real attempt was made but did NOT
/// verify (rolled back) → the hybrid router falls back to the driver.
struct NativeActionOutcome: Equatable, Sendable {
    let verified: Bool
    let summary: String
}

#if canImport(ApplicationServices)
import ApplicationServices
import CoreGraphics

enum NativeAXActuation {

    /// macOS/AppKit may not commit a value-set the instant the AX call returns; re-reading too early
    /// reports the stale value as a mismatch. ~130ms matches the rebuild backend's settle delay.
    private static let settleMicroseconds: useconds_t = 130_000

    // MARK: Action dispatch (AX-first; nil → driver fallback)

    /// Attempt a mutating verb in-process. nil = NOT a native candidate now (no trust, or the element
    /// is AX-opaque/unresolved) → the hybrid router uses the driver. A non-nil outcome carries whether
    /// the mutation verified.
    static func perform(_ request: NativeActionRequest) -> NativeActionOutcome? {
        guard AXElementResolver.isTrusted, let pid = request.pid else { return nil }
        switch request.kind {
        case .click, .rightClick, .doubleClick:
            return performClick(request, pid: pid)
        case .typeText:
            return performType(request, pid: pid)
        case .setValue:
            return performSetValue(request, pid: pid)
        }
    }

    /// Resolve a real element (point→element first, then element_index), click its CENTER, and treat
    /// the click as verified once posted. A click commits app-internal state with no AX-readable field
    /// to read back, so the verify here is element resolution + a posted action — the honest port of
    /// the rebuild's verify spirit, NOT the (0,0) stub (which clicked nothing real).
    private static func performClick(_ request: NativeActionRequest, pid: Int) -> NativeActionOutcome? {
        // Point→element (the (0,0) fix): if the call carried a point, click exactly there.
        if let point = request.point, AXElementResolver.element(at: point) != nil {
            postMouseClick(at: point, kind: request.kind)
            return NativeActionOutcome(verified: true, summary: "native-ax: \(label(request.kind)) at point")
        }
        // Else resolve the element_index against the in-process enumeration and click its center.
        guard let index = request.elementIndex,
              let resolved = AXElementResolver.element(ofPid: pid, atIndex: index) else {
            return nil  // AX-opaque / index no longer resolves → driver fallback.
        }
        // A real AX control's own press is the most reliable left-click; fall back to a CGEvent at
        // the element center for right/double clicks or controls without a press action.
        if request.kind == .click, AXElementResolver.press(resolved.element) {
            return NativeActionOutcome(verified: true, summary: "native-ax: pressed element \(index)")
        }
        guard let center = AXElementResolver.center(of: resolved.element) else { return nil }
        postMouseClick(at: center, kind: request.kind)
        return NativeActionOutcome(verified: true, summary: "native-ax: \(label(request.kind)) element \(index)")
    }

    /// Type into the focused field via CGEvent keystrokes, then VERIFY the focused value reflects the
    /// typed text; on mismatch, roll the field back to its captured prior value (INV-3 spirit).
    private static func performType(_ request: NativeActionRequest, pid: Int) -> NativeActionOutcome? {
        guard let text = request.text else { return nil }
        guard let focused = AXElementResolver.focusedElement(ofPid: pid) else { return nil }
        let prior = AXElementResolver.readString(focused, kAXValueAttribute)
        postKeystrokes(text)
        usleep(settleMicroseconds)
        let readBack = AXElementResolver.readString(focused, kAXValueAttribute)
        switch NativeActionPolicy.verifyTyped(prior: prior, readBack: readBack, typed: text) {
        case .verified:
            return NativeActionOutcome(verified: true, summary: "native-ax: typed \(text.count) chars")
        case .mismatchRollback:
            rollback(focused, to: prior)
            return NativeActionOutcome(verified: false, summary: "native-ax: type not verified, rolled back")
        }
    }

    /// Set the field's kAXValue (the cheap AX path), VERIFY by read-back, and on a Chromium/WebKit
    /// misfire fall back to CGEvent keystrokes — re-verifying — before giving up. A final mismatch
    /// rolls back to the captured prior value and returns unverified (→ driver fallback).
    private static func performSetValue(_ request: NativeActionRequest, pid: Int) -> NativeActionOutcome? {
        guard let value = request.value else { return nil }
        let element = resolveValueTarget(request, pid: pid)
        guard let element else { return nil }
        let prior = AXElementResolver.readString(element, kAXValueAttribute)

        _ = AXElementResolver.setValue(element, value)
        usleep(settleMicroseconds)
        if NativeActionPolicy.verifySetValue(
            readBack: AXElementResolver.readString(element, kAXValueAttribute), expected: value) == .verified {
            return NativeActionOutcome(verified: true, summary: "native-ax: set value (\(value.count) chars)")
        }

        // AX value-set did not land → CGEvent keystroke fallback through the same surface.
        postKeystrokes(value)
        usleep(settleMicroseconds)
        if NativeActionPolicy.verifySetValue(
            readBack: AXElementResolver.readString(element, kAXValueAttribute), expected: value) == .verified {
            return NativeActionOutcome(verified: true, summary: "native-ax: set value via keystroke fallback")
        }

        rollback(element, to: prior)
        return NativeActionOutcome(verified: false, summary: "native-ax: set value not verified, rolled back")
    }

    /// The element a value mutation targets: an explicit element_index if given, else the app's
    /// focused element (the natural target for set_value/type).
    private static func resolveValueTarget(_ request: NativeActionRequest, pid: Int) -> AXUIElement? {
        if let index = request.elementIndex {
            return AXElementResolver.element(ofPid: pid, atIndex: index)?.element
        }
        return AXElementResolver.focusedElement(ofPid: pid)
    }

    /// Restore a captured prior value (rollback) — itself best-effort through the AX value set.
    private static func rollback(_ element: AXUIElement, to prior: String?) {
        guard let prior else { return }
        _ = AXElementResolver.setValue(element, prior)
    }

    // MARK: In-process get_window_state (the live read path, not the driver)

    /// The focused/targeted window's AX state, read IN-PROCESS. Returns nil when there is no trust or
    /// the surface is AX-opaque (no actionable elements), so the hybrid driver falls back to the
    /// `cua-driver`. `windows` is the native window list (CGWindowList) the caller already holds; the
    /// surface is matched by pid+windowId so the returned state carries the rich `CuaWindow`.
    static func windowState(pid: Int, windowId: Int, windows: [CuaWindow]) -> CuaWindowState? {
        guard AXElementResolver.isTrusted else { return nil }
        guard let surface = windows.first(where: { $0.pid == pid && $0.windowId == windowId }) else {
            return nil
        }
        let resolved = AXElementResolver.enumerateElements(ofPid: pid)
        guard !resolved.isEmpty else { return nil }
        let elements = resolved.map {
            CuaElement(id: "element-\($0.index)", index: $0.index, role: $0.role, label: $0.label, value: $0.value)
        }
        return CuaWindowState(
            surface: surface, capturedAt: timestamp(), elementCount: elements.count, elements: elements)
    }

    // MARK: CGEvent primitives

    private static func postMouseClick(at point: CGPoint, kind: NativeActionKind) {
        let button: CGMouseButton = (kind == .rightClick) ? .right : .left
        let down: CGEventType = (kind == .rightClick) ? .rightMouseDown : .leftMouseDown
        let up: CGEventType = (kind == .rightClick) ? .rightMouseUp : .leftMouseUp
        let clicks = (kind == .doubleClick) ? 2 : 1
        for i in 1...clicks {
            guard let d = CGEvent(mouseEventSource: nil, mouseType: down, mouseCursorPosition: point, mouseButton: button),
                  let u = CGEvent(mouseEventSource: nil, mouseType: up, mouseCursorPosition: point, mouseButton: button) else { return }
            d.setIntegerValueField(.mouseEventClickState, value: Int64(i))
            u.setIntegerValueField(.mouseEventClickState, value: Int64(i))
            d.post(tap: .cghidEventTap)
            u.post(tap: .cghidEventTap)
        }
    }

    private static func postKeystrokes(_ text: String) {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return }
        for scalar in text.unicodeScalars {
            var utf16 = Array(String(scalar).utf16)
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else { continue }
            down.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
            up.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
        }
    }

    private static func label(_ kind: NativeActionKind) -> String {
        switch kind {
        case .click: return "click"
        case .rightClick: return "right_click"
        case .doubleClick: return "double_click"
        case .typeText: return "type_text"
        case .setValue: return "set_value"
        }
    }

    private static func timestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }
}

#else

/// Non-AX platforms (never the macOS app target): native actuation is unavailable, so every attempt
/// defers to the driver. Present only so the hybrid driver compiles platform-agnostically.
enum NativeAXActuation {
    static func perform(_ request: NativeActionRequest) -> NativeActionOutcome? { nil }
    static func windowState(pid: Int, windowId: Int, windows: [CuaWindow]) -> CuaWindowState? { nil }
}

#endif
