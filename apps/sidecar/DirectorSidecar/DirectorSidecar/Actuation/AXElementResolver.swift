//
//  AXElementResolver.swift
//  DirectorSidecar
//
//  #148 (the core fix) — the IN-PROCESS Accessibility read. This is the only file here that touches
//  the AX C-API, so the ApplicationServices import is isolated. It reads the AX tree using the
//  DIRECTOR's OWN TCC Accessibility grant instead of the external `cua-driver` (whose separate
//  `com.trycua.driver` identity is not granted, so its AX reads/clicks fail in the bundled app).
//
//  Two jobs, both ported from the user's rebuild source (SystemAXTreeProvider + the LiveAXActionBackend
//  element helpers), with the rebuild's gated defects dropped:
//    • enumerate a window's actionable elements into an ordered list (the same order the hybrid
//      driver's `get_window_state` emits), so an `element_index` maps back to a REAL element; and
//    • resolve a click POINT to the element under it (`AXUIElementCopyElementAtPosition`) — the
//      point→element fix that replaces the rebuild's hardcoded (0,0) click.
//
//  Untested by design: it needs TCC + real windows, so it is exercised only by the on-device manual
//  gate, never headless/CI (the pure decode/route/verify policy IS unit-tested).
//

#if canImport(ApplicationServices)
import ApplicationServices
import CoreGraphics
import AppKit

/// One actionable AX element resolved in-process: the live element handle plus the descriptive
/// fields `get_window_state` reports (role/label/value) and the on-screen frame the click targets.
struct ResolvedAXElement {
    let index: Int
    let element: AXUIElement
    let role: String?
    let label: String?
    let value: String?
    let frame: CGRect?
}

/// In-process AX reads, gated on `AXIsProcessTrusted()`. Stateless — every method reads live.
enum AXElementResolver {

    /// AX roles whose elements are actionable enough to offer the resolver / accept a click. Static
    /// text, groups, and scroll areas are containers, not targets, so they are walked but not listed.
    static let actionableRoles: Set<String> = [
        kAXButtonRole as String, kAXMenuButtonRole as String, kAXPopUpButtonRole as String,
        kAXMenuItemRole as String, "AXLink", kAXCheckBoxRole as String,
        kAXRadioButtonRole as String, kAXTextFieldRole as String, kAXTextAreaRole as String,
        kAXComboBoxRole as String, "AXSearchField", "AXTab", "AXDisclosureTriangle",
        kAXCellRole as String, kAXRowRole as String, kAXIncrementorRole as String,
    ]

    /// Whether this process holds the Accessibility grant. No trust → no in-process read, and the
    /// hybrid router falls back to the driver (never a silent no-op).
    static var isTrusted: Bool { AXIsProcessTrusted() }

    // MARK: Window resolution

    /// The AX front/main window for a pid — focused, then main, then first. (CGWindowList's numeric
    /// `windowId` has no stable AX counterpart, so the slice targets the app's front window; the
    /// loop observes and acts on the focused app, so pid is the load-bearing key.)
    static func frontWindow(ofPid pid: Int) -> AXUIElement? {
        // Electron/Chromium targets expose nothing until accessibility is requested — trigger it so a
        // Slack/Cursor window resolves natively instead of always falling back to the driver (#148).
        ElectronAccessibility.enable(forPid: pid)
        let app = AXUIElementCreateApplication(pid_t(pid))
        if let focused = copyElement(app, kAXFocusedWindowAttribute) { return focused }
        if let main = copyElement(app, kAXMainWindowAttribute) { return main }
        return copyElements(app, kAXWindowsAttribute).first
    }

    /// The app's focused UI element (kAXFocusedUIElement) — the target for type/set_value.
    static func focusedElement(ofPid pid: Int) -> AXUIElement? {
        ElectronAccessibility.enable(forPid: pid)
        let app = AXUIElementCreateApplication(pid_t(pid))
        return copyElement(app, kAXFocusedUIElementAttribute)
    }

    // MARK: Element enumeration (the in-process get_window_state element list)

    /// Depth-bounded pre-order walk of `window`, collecting actionable elements with stable indices.
    /// Bounded (depth + count) so a large tree (Slack/Cursor) can't stall the read; an AX-opaque
    /// surface simply yields `[]`, which the hybrid driver routes to the D18-style driver fallback.
    static func enumerateElements(
        ofPid pid: Int, maxDepth: Int = 12, maxCount: Int = 200
    ) -> [ResolvedAXElement] {
        guard isTrusted, let window = frontWindow(ofPid: pid) else { return [] }
        var out: [ResolvedAXElement] = []
        walk(window, depth: maxDepth, into: &out, maxCount: maxCount)
        return out
    }

    private static func walk(
        _ element: AXUIElement, depth: Int, into out: inout [ResolvedAXElement], maxCount: Int
    ) {
        guard out.count < maxCount else { return }
        if let role = readString(element, kAXRoleAttribute), actionableRoles.contains(role) {
            out.append(ResolvedAXElement(
                index: out.count,
                element: element,
                role: role,
                label: readString(element, kAXTitleAttribute) ?? readString(element, kAXDescriptionAttribute),
                value: readString(element, kAXValueAttribute),
                frame: frame(of: element)))
        }
        guard depth > 0 else { return }
        for child in copyElements(element, kAXChildrenAttribute) {
            if out.count >= maxCount { return }
            walk(child, depth: depth - 1, into: &out, maxCount: maxCount)
        }
    }

    /// The actionable element at index `index` in the live enumeration (the index the resolver
    /// picked from `get_window_state`). nil when the tree changed and the index no longer resolves.
    static func element(ofPid pid: Int, atIndex index: Int) -> ResolvedAXElement? {
        enumerateElements(ofPid: pid).first(where: { $0.index == index })
    }

    // MARK: Point → element (the (0,0) fix)

    /// The element under a CG-global point via `AXUIElementCopyElementAtPosition` — the real
    /// point→element resolver that replaces the rebuild's hardcoded (0,0). nil when no trust or the
    /// point hits an AX-opaque surface.
    static func element(at point: CGPoint) -> AXUIElement? {
        guard isTrusted else { return nil }
        let systemWide = AXUIElementCreateSystemWide()
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(point.y), &hit) == .success else {
            return nil
        }
        return hit
    }

    // MARK: Geometry + attribute reads (isolated AX C-API)

    /// The center of an element's frame — the CG-global click point (NOT (0,0)).
    static func center(of element: AXUIElement) -> CGPoint? {
        guard let f = frame(of: element) else { return nil }
        return CGPoint(x: f.midX, y: f.midY)
    }

    static func frame(of element: AXUIElement) -> CGRect? {
        guard let origin = readPoint(element, kAXPositionAttribute),
              let size = readSize(element, kAXSizeAttribute) else { return nil }
        return CGRect(origin: origin, size: size)
    }

    /// Perform the element's native press if it exposes one (kAXPress) — the cheapest, most reliable
    /// "click" for a real AX control. Returns whether the press was accepted.
    @discardableResult
    static func press(_ element: AXUIElement) -> Bool {
        AXUIElementPerformAction(element, kAXPressAction as CFString) == .success
    }

    /// Set an element's kAXValue to a string. Returns whether the set was accepted.
    @discardableResult
    static func setValue(_ element: AXUIElement, _ value: String) -> Bool {
        AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, value as CFString) == .success
    }

    static func readString(_ element: AXUIElement, _ attribute: String) -> String? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success,
              let object = raw else { return nil }
        if CFGetTypeID(object) == CFStringGetTypeID() { return (object as! String) }
        if let number = object as? NSNumber { return number.stringValue }
        return nil
    }

    private static func readPoint(_ element: AXUIElement, _ attribute: String) -> CGPoint? {
        guard let v = copyAXValue(element, attribute) else { return nil }
        var point = CGPoint.zero
        guard AXValueGetType(v) == .cgPoint, AXValueGetValue(v, .cgPoint, &point) else { return nil }
        return point
    }

    private static func readSize(_ element: AXUIElement, _ attribute: String) -> CGSize? {
        guard let v = copyAXValue(element, attribute) else { return nil }
        var size = CGSize.zero
        guard AXValueGetType(v) == .cgSize, AXValueGetValue(v, .cgSize, &size) else { return nil }
        return size
    }

    private static func copyAXValue(_ element: AXUIElement, _ attribute: String) -> AXValue? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success,
              let object = raw, CFGetTypeID(object) == AXValueGetTypeID() else { return nil }
        return (object as! AXValue)
    }

    private static func copyElement(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success,
              let object = raw, CFGetTypeID(object) == AXUIElementGetTypeID() else { return nil }
        return (object as! AXUIElement)
    }

    private static func copyElements(_ element: AXUIElement, _ attribute: String) -> [AXUIElement] {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success,
              let array = raw as? [AXUIElement] else { return [] }
        return array
    }
}
#endif
