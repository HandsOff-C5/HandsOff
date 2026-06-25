//
//  RailPanel.swift
//  DirectorSidecar
//
//  The Right-edge rail's host: a borderless, non-activating NSPanel pinned to the screen edge
//  (right by default, or left per the onboarding `listenEdge` choice), vertically centered. The
//  capsule is interactive (Open-Home button); the OS draws the rounded shadow. Shown whenever the
//  rail has content (running agents or listening). Built AFTER launch (never in App.init).
//

import SwiftUI
import AppKit

final class RailPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class RailController {
    enum Edge { case leading, trailing }

    private let model: RailModel
    private let onOpenHome: () -> Void
    private let edge: Edge
    private let inset: CGFloat = 12
    private var panel: RailPanel?

    init(model: RailModel, edge: Edge = .trailing, onOpenHome: @escaping () -> Void) {
        self.model = model
        self.edge = edge
        self.onOpenHome = onOpenHome
        observeVisibility()
        applyVisibility()
        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil
        )
    }

    // MARK: observation

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

    @objc private func screensChanged() {
        if panel?.isVisible == true { anchor() }
    }

    // MARK: panel

    private func show() {
        let panel = panel ?? makePanel()
        self.panel = panel
        anchor()
        panel.orderFrontRegardless() // never makeKey/activate — must not steal focus
    }

    private func hide() { panel?.orderOut(nil) }

    private func makePanel() -> RailPanel {
        let panel = RailPanel(
            contentRect: NSRect(x: 0, y: 0, width: 64, height: 240),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true // OS draws the capsule's rounded shadow from the content's alpha shape
        let host = NSHostingView(rootView: ThemedRoot {
            RailView(model: model, onExpand: onOpenHome)
        })
        panel.contentView = host
        return panel
    }

    private func anchor() {
        guard let panel, let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let size = panel.contentView?.fittingSize ?? NSSize(width: 64, height: 240)
        panel.setContentSize(size)
        let x: CGFloat = edge == .trailing
            ? visible.maxX - size.width - inset
            : visible.minX + inset
        let y = visible.midY - size.height / 2
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}
