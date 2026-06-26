//
//  RailPanel.swift
//  DirectorSidecar
//
//  The Right-edge rail's host: a borderless, non-activating NSPanel pinned to the screen edge
//  (right by default, or left per the onboarding `listenEdge` choice), vertically centered. The
//  capsule is interactive (Open-Home button); the OS draws the rounded shadow. Shown only while
//  Director is listening (fn held) and Home is closed. Built AFTER launch (never in App.init).
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
    private let store: BridgeStore
    private let edge: Edge
    private let inset: CGFloat = 12
    /// The panel is a FIXED width, anchored by its right edge — it never resizes on hover, so the
    /// window can't move and the right edge physically cannot shift. The capsule hugs its content
    /// and animates LEFTWARD inside this fixed window (right-aligned). The collapsed icon column
    /// sits at the right; the transparent area to its left is non-interactive (clicks pass through).
    private let panelWidth: CGFloat = 172
    private var panel: RailPanel?

    init(model: RailModel, edge: Edge = .trailing, store: BridgeStore) {
        self.model = model
        self.edge = edge
        self.store = store
        observe()
        applyVisibility()
        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil
        )
    }

    // MARK: observation

    /// Re-evaluate on visibility + content changes (height: listening/marks). Hover is separate.
    private func observe() {
        withObservationTracking {
            _ = model.isVisible
            _ = model.isListening
            _ = model.marks
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.applyVisibility()
                self.observe()
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
        let firstShow = !panel.isVisible
        anchor()                          // fixed width; only height (content) can change here
        if firstShow { panel.orderFrontRegardless() } // never makeKey/activate — must not steal focus
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
            RailView(model: model, store: store)
        })
        panel.contentView = host
        return panel
    }

    private func anchor() {
        guard let panel, let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        // FIXED width — never hover-dependent. Only the height follows the content (mark count).
        // Because the width and right edge never change, the window never moves on hover.
        let width = panelWidth
        let height = panel.contentView?.fittingSize.height ?? 240
        let x: CGFloat = edge == .trailing
            ? visible.maxX - width - inset
            : visible.minX + inset
        let y = visible.midY - height / 2
        panel.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
        #if DEBUG
        print("[RAIL] anchor — width=\(width) rightEdge=\(x + width) (should equal screenMaxX-inset=\(visible.maxX - inset)); fires on show/screen/content only, NOT hover")
        #endif
    }
}
