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
    private var window: OverlayWindow?
    private var mouseMonitor: Any?

    init(model: OverlayModel) {
        self.model = model
        observeVisibility()
        startMouseMonitor()
        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil
        )
    }

    private func observeVisibility() {
        withObservationTracking {
            _ = model.isVisible
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.applyVisibility()
                self.observeVisibility()
            }
        }
    }

    private func applyVisibility() {
        if model.isVisible { show() } else { hide() }
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
        let window = window ?? makeWindow()
        self.window = window
        window.orderFrontRegardless() // never makeKey/activate — must not steal focus
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
        // Click-through is enforced by the window (ignoresMouseEvents) + the view's
        // .allowsHitTesting(false); the host NSView needs no extra config.
        window.contentView = NSHostingView(rootView: ThemedRoot {
            ReticleOverlayView(model: model, primaryHeight: frame.height)
        })
        return window
    }
}
