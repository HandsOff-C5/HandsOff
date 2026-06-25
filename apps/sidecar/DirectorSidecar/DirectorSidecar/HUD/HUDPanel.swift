//
//  HUDPanel.swift
//  DirectorSidecar
//
//  G2 (T-G2.2): the non-activating floating panel that hosts the Listening HUD. It never steals
//  focus from the pointed-at app (canBecomeKey/Main = false), floats across Spaces + fullscreen,
//  and is edge-anchored. The controller shows/hides it by observing HUDModel.isVisible and
//  re-anchors on screen changes.
//

import SwiftUI
import AppKit

/// A borderless, non-activating HUD panel. Buttons are still clickable (ignoresMouseEvents=false),
/// but the panel never becomes key/main, so the app the user is pointing at keeps focus.
final class HUDPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class HUDPanelController {
    enum Edge { case leading, trailing }

    private let model: HUDModel
    private let edge: Edge
    private let inset: CGFloat = 28
    private let width: CGFloat = 300
    private var panel: HUDPanel?

    init(model: HUDModel, edge: Edge = .trailing) {
        self.model = model
        self.edge = edge
        observeVisibility()
        apply(visible: model.showsFullPanel) // sync current state — controller is built after launch now
        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil
        )
    }

    // MARK: Observation → show/hide

    private func observeVisibility() {
        withObservationTracking {
            _ = model.showsFullPanel
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.apply(visible: self.model.showsFullPanel)
                self.observeVisibility() // re-arm
            }
        }
    }

    private func apply(visible: Bool) {
        if visible { show() } else { hide() }
    }

    @objc private func screensChanged() {
        if panel?.isVisible == true { anchor() }
    }

    // MARK: Panel lifecycle

    private func show() {
        let panel = panel ?? makePanel()
        self.panel = panel
        anchor()
        panel.orderFrontRegardless() // show without activating the app
    }

    private func hide() {
        panel?.orderOut(nil)
    }

    private func makePanel() -> HUDPanel {
        let panel = HUDPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: 200),
            styleMask: [.nonactivatingPanel, .borderless, .hudWindow],
            backing: .buffered, defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.ignoresMouseEvents = false

        let host = NSHostingView(rootView: ThemedRoot { ListeningHUDView(model: model) })
        host.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView = host
        return panel
    }

    private func anchor() {
        guard let panel, let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let host = panel.contentView
        let height = host?.fittingSize.height ?? 200
        panel.setContentSize(NSSize(width: width, height: max(height, 80)))
        let x: CGFloat = edge == .trailing
            ? visible.maxX - width - inset
            : visible.minX + inset
        let y = visible.midY - panel.frame.height / 2
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}
