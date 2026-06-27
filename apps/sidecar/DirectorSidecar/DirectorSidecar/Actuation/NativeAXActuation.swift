//
//  NativeAXActuation.swift
//  DirectorSidecar
//
//  #148 — the in-process native AX action backend: the one place native click / type_text / set_value
//  side effects fire, using the Director's OWN Accessibility grant (not the `cua-driver`). It composes
//  the pure policy (route + verify) with the live `AXElementResolver`, and performs the read-back
//  verify→rollback ported from the rebuild's ActionActuator. It NEVER fakes success: a verb whose
//  element does not resolve falls back to the driver; a resolved mutation that does not verify is
//  rolled back and surfaced as a failure — never a silent no-op.
//
//  This backend sits BEHIND the loop's existing ToolCallGate (every mutating step is gated/approved
//  before dispatch reaches the driver — see VoiceCuaLoop.runGoalAction → StepDispatch.firstBlockedStep),
//  so nothing here weakens approval. Live-only: verified on-device, never headless (the pure parts are).
//

import Foundation

/// The outcome of a native actuation attempt — a three-way result so the hybrid driver can tell a
/// "couldn't do it natively" case (→ driver fallback) apart from a "tried natively, it didn't take"
/// case (→ a failure result; NOT a driver re-attempt, which would double-actuate):
///   • `verified`     — the mutation landed and the read-back confirmed it (or, for a click, a real
///                      element resolved and the press/click posted; a click has no AX-readable field
///                      to compare). → success.
///   • `failedVerify` — a real native mutation was attempted on a resolved element but the read-back
///                      did NOT match; the prior value was rolled back. → a FAILURE result, surfaced
///                      to the loop (never silent), with no driver re-attempt.
///   • `notResolved`  — no Accessibility trust, an AX-opaque surface, or the element could not be
///                      resolved → the hybrid driver falls back to the `cua-driver`.
enum NativeActionOutcome: Equatable, Sendable {
    case verified(summary: String)
    case failedVerify(reason: String)
    case notResolved
}

#if canImport(ApplicationServices)
import ApplicationServices
import CoreGraphics

enum NativeAXActuation {

    /// macOS/AppKit may not commit a value-set the instant the AX call returns; re-reading too early
    /// reports the stale value as a mismatch. ~130ms matches the rebuild backend's settle delay.
    private static let settleMicroseconds: useconds_t = 130_000

    // MARK: Action dispatch (AX-first; .notResolved → driver fallback)

    /// Attempt a mutating verb in-process. `.notResolved` = NOT a native candidate now (no trust, or
    /// the element is AX-opaque/unresolved) → the hybrid router uses the driver. `.verified`/
    /// `.failedVerify` mean a real native attempt was made.
    static func perform(_ request: NativeActionRequest) -> NativeActionOutcome {
        guard AXElementResolver.isTrusted, let pid = request.pid else { return .notResolved }
        switch request.kind {
        case .click, .rightClick, .doubleClick:
            return performClick(request, pid: pid)
        case .typeText:
            return performType(request, pid: pid)
        case .setValue:
            return performSetValue(request, pid: pid)
        }
    }

    /// Resolve a real element (point→element first, then element_index) and activate it. A click
    /// commits app-internal state with no AX-readable field to read back, so the verify here is
    /// element resolution + a posted action — the honest port of the rebuild's verify spirit, NOT the
    /// (0,0) stub (which clicked nothing real).
    private static func performClick(_ request: NativeActionRequest, pid: Int) -> NativeActionOutcome {
        // Point→element (the (0,0) fix): resolve the element under the point; a real control's own
        // press is the most reliable activation, else click the point directly.
        if let point = request.point, let element = AXElementResolver.element(at: point) {
            if request.kind == .click, AXElementResolver.press(element) {
                return .verified(summary: "native-ax: pressed element at point")
            }
            postMouseClick(at: point, kind: request.kind)
            return .verified(summary: "native-ax: \(label(request.kind)) at point")
        }
        // Else resolve the element_index against the in-process enumeration and click its center.
        guard let index = request.elementIndex,
              let resolved = AXElementResolver.element(ofPid: pid, atIndex: index) else {
            return .notResolved  // AX-opaque / index no longer resolves → driver fallback.
        }
        // A real AX control's own press is the most reliable left-click; fall back to a CGEvent at
        // the element center for right/double clicks or controls without a press action.
        if request.kind == .click, AXElementResolver.press(resolved.element) {
            return .verified(summary: "native-ax: pressed element \(index)")
        }
        guard let center = AXElementResolver.center(of: resolved.element) else { return .notResolved }
        postMouseClick(at: center, kind: request.kind)
        return .verified(summary: "native-ax: \(label(request.kind)) element \(index)")
    }

    /// Type into the focused field via CGEvent keystrokes, then VERIFY the focused value reflects the
    /// typed text; on mismatch, roll the field back to its captured prior value (INV-3 spirit).
    private static func performType(_ request: NativeActionRequest, pid: Int) -> NativeActionOutcome {
        guard let text = request.text else { return .notResolved }
        guard let focused = AXElementResolver.focusedElement(ofPid: pid) else { return .notResolved }
        let prior = AXElementResolver.readString(focused, kAXValueAttribute)
        postKeystrokes(text)
        usleep(settleMicroseconds)
        let readBack = AXElementResolver.readString(focused, kAXValueAttribute)
        switch NativeActionPolicy.verifyTyped(prior: prior, readBack: readBack, typed: text) {
        case .verified:
            return .verified(summary: "native-ax: typed \(text.count) chars")
        case .mismatchRollback:
            rollback(focused, to: prior)
            return .failedVerify(reason: "native-ax: type did not verify on AX re-read (rolled back)")
        }
    }

    /// Set the field's kAXValue (the cheap AX path), VERIFY by read-back, and on a Chromium/WebKit
    /// misfire fall back to CGEvent keystrokes — re-verifying — before giving up. A final mismatch
    /// rolls back to the captured prior value and reports a failure (never silent).
    private static func performSetValue(_ request: NativeActionRequest, pid: Int) -> NativeActionOutcome {
        guard let value = request.value else { return .notResolved }
        guard let element = resolveValueTarget(request, pid: pid) else { return .notResolved }
        let prior = AXElementResolver.readString(element, kAXValueAttribute)

        _ = AXElementResolver.setValue(element, value)
        usleep(settleMicroseconds)
        if NativeActionPolicy.verifySetValue(
            readBack: AXElementResolver.readString(element, kAXValueAttribute), expected: value) == .verified {
            return .verified(summary: "native-ax: set value (\(value.count) chars)")
        }

        // AX value-set did not land → CGEvent keystroke fallback through the same surface.
        postKeystrokes(value)
        usleep(settleMicroseconds)
        if NativeActionPolicy.verifySetValue(
            readBack: AXElementResolver.readString(element, kAXValueAttribute), expected: value) == .verified {
            return .verified(summary: "native-ax: set value via keystroke fallback")
        }

        rollback(element, to: prior)
        return .failedVerify(reason: "native-ax: set_value did not verify on AX re-read (rolled back)")
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

    /// Synthesizes a Cmd+V (paste) keystroke pair via CGEvent — the Cmd+V dispatch the Clipboard
    /// layer (FormattedClipboard) relies on for the Beat 1 formatted-drop, kept here in the
    /// actuation layer per the Clipboard module's contract.
    static func postPaste() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true) // 0x09 = 'v'
        down?.flags = .maskCommand
        let up   = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
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
    static func perform(_ request: NativeActionRequest) -> NativeActionOutcome { .notResolved }
    static func windowState(pid: Int, windowId: Int, windows: [CuaWindow]) -> CuaWindowState? { nil }
    static func postPaste() {}
}

#endif
