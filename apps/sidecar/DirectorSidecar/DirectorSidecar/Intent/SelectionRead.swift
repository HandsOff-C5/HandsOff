//
//  SelectionRead.swift
//  DirectorSidecar
//
//  Capability surface for plan U9 — read the on-screen text the user pointed at so a
//  compose/act goal can ground "this" in real content instead of guessing. Two read paths,
//  both passive (we NEVER synthesize ⌘C or move focus):
//
//    1. selectedText(forPid:)        — AX focused-element selected text on the binder-resolved
//                                      surface's pid. Gated by AXIsProcessTrusted, excludes our
//                                      own bundle, compacted and capped (~1500 chars).
//    2. clipboardIfChanged(since…:)  — the general pasteboard string, but ONLY when its
//                                      changeCount advanced past the baseline captured when
//                                      listening began. A stale clipboard reads as nil.
//
//  This file is the pure capability only — no wiring. HeadPointingIntake.makeInput anchors these
//  to the TemporalBinder-resolved surface (the binder stays authoritative for *which* surface;
//  U9 only adds *the text within it*). The string-shaping cores are static and side-effect free
//  so the cap and changeCount gating are fixture-testable without a live AX tree or pasteboard.
//
//  Port: OpenClickyNotchCaptureWindowManager.swift:1727 (AX focused selection) and
//  CompanionManager.swift:15028 (change-count-gated NSPasteboard read).
//

import AppKit
import ApplicationServices
import Foundation
import OSLog

enum SelectionRead {
    /// Upper bound on the text we hand to the LLM — keeps a giant selection from blowing the prompt.
    static let maxLength = 1_500

    // MARK: - AX focused selection

    /// AX-read the focused element's selected text from `pid`'s application.
    ///
    /// Returns nil (never throws, never crashes) when Accessibility is not trusted, when `pid`
    /// is our own process/bundle, when the app exposes no focused element, or when there is no
    /// selected text. A missing AX grant therefore degrades to an empty selection — the loop can
    /// still read via the AX snapshot / vision (U6).
    static func selectedText(forPid pid: pid_t) -> String? {
        guard AXIsProcessTrusted() else {
            DirectorDiagnostics.services.debug("SelectionRead.selectedText: AX not trusted")
            return nil
        }
        guard !isOwnProcess(pid) else { return nil }

        let appElement = AXUIElementCreateApplication(pid)
        // Bound every AX message: `makeInput` calls this SYNCHRONOUSLY at goal-start, and
        // AXUIElementCopyAttributeValue blocks until the target app services the request — an
        // unresponsive (or hung, or AX-uncooperative) app would otherwise freeze the whole goal loop
        // indefinitely (and deadlock a hosted XCTest where Accessibility is persisted-granted). 0.2s is
        // ample for a healthy app; a slow one yields an AX error → nil (degrade to no selection).
        AXUIElementSetMessagingTimeout(appElement, 0.2)
        var focusedValue: CFTypeRef?
        let focusedResult = AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedValue
        )
        guard focusedResult == .success,
              let focusedValue,
              CFGetTypeID(focusedValue) == AXUIElementGetTypeID() else {
            return nil
        }

        // swiftlint:disable:next force_cast — guarded by the AXUIElementGetTypeID check above.
        let focusedElement = focusedValue as! AXUIElement
        var selectedValue: CFTypeRef?
        let selectedResult = AXUIElementCopyAttributeValue(
            focusedElement,
            kAXSelectedTextAttribute as CFString,
            &selectedValue
        )
        guard selectedResult == .success, let rawText = selectedValue as? String else {
            return nil
        }
        return normalizedSelection(rawText)
    }

    // MARK: - Change-count-gated clipboard

    /// The general pasteboard's string, but ONLY if its `changeCount` advanced past `baseline`.
    ///
    /// `baseline` is the `NSPasteboard.general.changeCount` captured when listening began. We
    /// never write to or synthesize a copy into the pasteboard — a clipboard that has not changed
    /// since the baseline is treated as "not the user's selection" and yields nil.
    static func clipboardIfChanged(sinceChangeCount baseline: Int) -> String? {
        let pasteboard = NSPasteboard.general
        return clipboardSelection(
            changeCount: pasteboard.changeCount,
            baseline: baseline,
            value: pasteboard.string(forType: .string)
        )
    }

    // MARK: - Pure cores (fixture-testable)

    /// Gating + shaping for a change-count-gated clipboard read, isolated from `NSPasteboard`.
    /// Returns the normalized `value` only when `changeCount` is strictly greater than `baseline`.
    static func clipboardSelection(changeCount: Int, baseline: Int, value: String?) -> String? {
        guard changeCount > baseline else { return nil }
        guard let value else { return nil }
        return normalizedSelection(value)
    }

    /// Collapse runs of blank lines, trim surrounding whitespace, and cap at `maxLength`.
    /// Returns nil when the result is empty so callers get a clean optional.
    static func normalizedSelection(_ raw: String) -> String? {
        let compact = raw
            .replacingOccurrences(of: "\\n{2,}", with: "\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !compact.isEmpty else { return nil }
        return String(compact.prefix(maxLength))
    }

    // MARK: - Own-bundle exclusion

    /// True when `pid` is our own process, or a process whose bundle id matches ours — so we never
    /// read the Director's own UI as if it were the user's pointed surface.
    private static func isOwnProcess(_ pid: pid_t) -> Bool {
        if pid == ProcessInfo.processInfo.processIdentifier { return true }
        if let running = NSRunningApplication(processIdentifier: pid),
           let bundleId = running.bundleIdentifier,
           bundleId == Bundle.main.bundleIdentifier {
            return true
        }
        return false
    }
}
