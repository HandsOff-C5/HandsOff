//
//  MicroHUDPanel.swift
//  DirectorSidecar
//
//  G3: the non-activating, edge-pinned micro-HUD panel + its controller. Click-through
//  (ignoresMouseEvents=true) while ambient/agent-working, toggled clickable during the idle
//  edge-hover reveal so the Open-Home click lands. A global mouse monitor feeds cursor-at-edge
//  to the model; the controller shows/hides + re-anchors via observation and screen-change events.
//

import SwiftUI
import AppKit

final class MicroHUDPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class MicroHUDController {
    private let model: MicroHUDModel
    private let onOpenHome: () -> Void
    private let inset: CGFloat = 28
    private let width: CGFloat = 232
    private var panel: MicroHUDPanel?
    private var mouseMonitor: Any?

    init(model: MicroHUDModel, fullHUD: HUDModel, onOpenHome: @escaping () -> Void) {
        self.model = model
        self.onOpenHome = onOpenHome
        observePhase()
        observeFullHUD(fullHUD)
        startEdgeMonitor()
        applyPhase() // sync current state — controller is built after launch now (else the pill can miss it)
        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil
        )
    }

    /// When the full HUD takes the screen (real content), the micro yields (hidden).
    private func observeFullHUD(_ fullHUD: HUDModel) {
        withObservationTracking {
            _ = fullHUD.showsFullPanel
        } onChange: { [weak self, weak fullHUD] in
            Task { @MainActor in
                guard let self, let fullHUD else { return }
                self.model.setFullHUDActive(fullHUD.showsFullPanel)
                self.observeFullHUD(fullHUD)
            }
        }
    }

    // MARK: observation

    private func observePhase() {
        withObservationTracking {
            _ = model.phase
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.applyPhase()
                self.observePhase()
            }
        }
    }

    private func applyPhase() {
        if model.isVisible { show() } else { hide() }
        // Click-through everywhere except the idle reveal (where Open-Home must be clickable).
        panel?.ignoresMouseEvents = model.phase != .edgeHoverReveal
    }

    @objc private func screensChanged() {
        if panel?.isVisible == true { anchor() }
    }

    // MARK: edge-hover monitor (idle reveal)

    private func startEdgeMonitor() {
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
            // Update directly on the main thread — a Task per mouse-move event floods the main
            // actor and freezes the UI (the cause of the unclickable dashboard + beachball).
            MainActor.assumeIsolated {
                guard let self, let screen = NSScreen.main else { return }
                let at = MicroHUDModel.isAtEdge(
                    cursor: NSEvent.mouseLocation, screen: screen.frame, edge: self.model.listenEdge
                )
                self.model.setCursorAtEdge(at)
            }
        }
    }

    // MARK: panel

    private func show() {
        let panel = panel ?? makePanel()
        self.panel = panel
        anchor()
        panel.orderFrontRegardless()
    }

    private func hide() { panel?.orderOut(nil) }

    private func makePanel() -> MicroHUDPanel {
        let panel = MicroHUDPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: 60),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        let host = NSHostingView(rootView: ThemedRoot {
            MicroHUDView(model: model, onOpenHome: onOpenHome)
        })
        panel.contentView = host
        return panel
    }

    private func anchor() {
        guard let panel, let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let height = panel.contentView?.fittingSize.height ?? 60
        panel.setContentSize(NSSize(width: width, height: max(height, 44)))
        let x: CGFloat = model.listenEdge == .trailing
            ? visible.maxX - width - inset
            : visible.minX + inset
        let y = visible.midY - panel.frame.height / 2
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}
