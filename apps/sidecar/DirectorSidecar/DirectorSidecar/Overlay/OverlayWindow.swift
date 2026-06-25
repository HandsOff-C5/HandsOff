//
//  OverlayWindow.swift
//  DirectorSidecar
//
//  G5: a borderless, transparent, click-through, always-on-top NSWindow floating the Director +
//  agent cursors over the real desktop. The core invariant is ignoresMouseEvents=true (clicks pass
//  through). The controller shows/hides via observation and feeds the live system-cursor position
//  (for the Director cursor's hug) from a global mouse monitor.
//

import SwiftUI
import AppKit

final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class OverlayController {
    private let model: OverlayModel
    private let gaze: GazeBracketModel
    /// One passthrough window PER display (folded in from the gesture-overlay sidecar). A cursor /
    /// gaze region on a secondary monitor now draws on THAT monitor instead of being clamped to the
    /// primary screen. Empty until `show()`; torn down and rebuilt on a display-config change.
    private var windows: [OverlayWindow] = []
    private var cursorPoll: Timer?

    init(model: OverlayModel, gaze: GazeBracketModel) {
        self.model = model
        self.gaze = gaze
        observeVisibility()
        applyVisibility() // sync current state — controller is built after launch now
        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil
        )
    }

    /// The one passthrough window shows when EITHER the cursors or the gaze brackets are visible.
    private var shouldShow: Bool { model.isVisible || gaze.isVisible }

    private func observeVisibility() {
        withObservationTracking {
            _ = model.isVisible
            _ = gaze.isVisible
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.applyVisibility()
                self.observeVisibility()
            }
        }
    }

    private func applyVisibility() {
        if shouldShow { show() } else { hide() }
    }

    // The Director cursor hugs the OS pointer. A global .mouseMoved monitor only fires while the
    // pointer is over OTHER apps, so the hug freezes over our own windows and jumps when it leaves
    // them (jitter). Poll NSEvent.mouseLocation each frame instead — smooth everywhere — and only
    // while the overlay is on screen. (.common run-loop mode keeps it ticking during UI tracking.)
    private func startCursorTracking() {
        guard cursorPoll == nil else { return }
        model.setSystemCursor(NSEvent.mouseLocation) // seed immediately so the cursor starts at the pointer
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.model.setSystemCursor(NSEvent.mouseLocation) }
        }
        RunLoop.main.add(timer, forMode: .common)
        cursorPoll = timer
    }

    private func stopCursorTracking() {
        cursorPoll?.invalidate()
        cursorPoll = nil
    }

    // A display added/removed/rearranged invalidates the whole window set (frames AND which
    // contract origin each window localizes to). Rebuild from scratch rather than patch frames.
    @objc private func screensChanged() {
        guard !windows.isEmpty else { return } // only while shown
        rebuildWindows()
    }

    private func show() {
        if windows.isEmpty { buildWindows() }
        for window in windows {
            window.orderFrontRegardless() // never makeKey/activate — must not steal focus
        }
        startCursorTracking()
    }

    private func hide() {
        for window in windows { window.orderOut(nil) }
        stopCursorTracking()
    }

    private func rebuildWindows() {
        for window in windows { window.orderOut(nil) }
        windows.removeAll()
        buildWindows()
        for window in windows { window.orderFrontRegardless() }
    }

    private func buildWindows() {
        // Contract space is anchored at the PRIMARY (menu-bar / origin) screen — `NSScreen.screens`
        // index 0 — NOT `NSScreen.main` (which is the key-window screen and moves with focus). The
        // y-flip in `resolvedViewPoint` is around this height, so every window must share it.
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        // The CG display layout (contract space). Built once per window-set so every window resolves
        // cursors against the SAME snapshot the windows were sized from — no per-frame CG calls.
        let displays = DisplayGeometry.activeDisplays()
        for screen in NSScreen.screens {
            guard let displayID = Self.displayID(of: screen) else { continue }
            windows.append(makeWindow(for: screen, displayID: displayID, displays: displays, primaryHeight: primaryHeight))
        }
    }

    /// The `CGDirectDisplayID` (widened to `Int`) backing an NSScreen — the join key to `DisplayRect`.
    /// `NSScreen` exposes it only via the untyped `deviceDescription[NSScreenNumber]` NSNumber.
    private static func displayID(of screen: NSScreen) -> Int? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber).map { Int($0.uint32Value) }
    }

    /// One passthrough window covering `screen`, hosting both overlay layers. Each layer resolves a
    /// contract-space point to a display via `DisplayGeometry` and only draws the points this window's
    /// `displayID` owns — so a cursor / gaze region renders on exactly the monitor it belongs to.
    private func makeWindow(for screen: NSScreen, displayID: Int, displays: [DisplayRect], primaryHeight: CGFloat) -> OverlayWindow {
        let window = OverlayWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        // .floating sits above other apps' normal windows (so the cursor/brackets draw over them)
        // but BELOW menus + the menu-bar dropdown, so activating Director never hides the menu.
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        window.ignoresMouseEvents = true
        // One passthrough window hosts both overlay layers: the gaze brackets (behind) + the
        // cursors (in front). Click-through is enforced by the window (ignoresMouseEvents) + the
        // views' .allowsHitTesting(false); the host NSView needs no extra config.
        window.contentView = NSHostingView(rootView: ThemedRoot {
            ZStack {
                GazeBracketLayer(model: gaze, displays: displays, displayID: displayID)
                ReticleOverlayView(model: model, primaryHeight: primaryHeight, displays: displays, displayID: displayID)
            }
        })
        return window
    }
}
