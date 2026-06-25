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
    private var window: OverlayWindow?
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

    @objc private func screensChanged() {
        if let window, let frame = NSScreen.main?.frame { window.setFrame(frame, display: true) }
    }

    private func show() {
        let shownWindow = window ?? makeWindow()
        self.window = shownWindow
        shownWindow.orderFrontRegardless() // never makeKey/activate — must not steal focus
        startCursorTracking()
    }

    private func hide() {
        window?.orderOut(nil)
        stopCursorTracking()
    }

    private func makeWindow() -> OverlayWindow {
        let frame = NSScreen.main?.frame ?? .zero
        let window = OverlayWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
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
        let primaryHeight = frame.height
        window.contentView = NSHostingView(rootView: ThemedRoot {
            ZStack {
                GazeBracketLayer(model: gaze)
                ReticleOverlayView(model: model, primaryHeight: primaryHeight)
            }
        })
        return window
    }
}
