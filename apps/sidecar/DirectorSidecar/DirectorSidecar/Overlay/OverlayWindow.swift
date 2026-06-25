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
    private var mouseMonitor: Any?

    init(model: OverlayModel, gaze: GazeBracketModel) {
        self.model = model
        self.gaze = gaze
        observeVisibility()
        startMouseMonitor()
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

    private func startMouseMonitor() {
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
            Task { @MainActor in self?.model.setSystemCursor(NSEvent.mouseLocation) }
        }
    }

    @objc private func screensChanged() {
        if let window, let frame = NSScreen.main?.frame { window.setFrame(frame, display: true) }
    }

    private func show() {
        let shownWindow = window ?? makeWindow()
        self.window = shownWindow
        shownWindow.orderFrontRegardless() // never makeKey/activate — must not steal focus
    }

    private func hide() { window?.orderOut(nil) }

    private func makeWindow() -> OverlayWindow {
        let frame = NSScreen.main?.frame ?? .zero
        let window = OverlayWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .screenSaver
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
