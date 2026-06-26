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
    private let onOpenHome: () -> Void
    private let edge: Edge
    private let inset: CGFloat = 12
    /// Collapsed = an icon column; expanded (hover) = wide enough for the row labels. Fixed widths
    /// (not fittingSize) so the panel footprint is small when idle and never blocks clicks behind it.
    private let collapsedWidth: CGFloat = 56
    private let expandedWidth: CGFloat = 200
    private var panel: RailPanel?

    init(model: RailModel, edge: Edge = .trailing, onOpenHome: @escaping () -> Void) {
        self.model = model
        self.edge = edge
        self.onOpenHome = onOpenHome
        observe()
        applyVisibility()
        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil
        )
    }

    // MARK: observation

    /// Re-evaluate on visibility, hover (width), and content changes (height: listening/marks).
    private func observe() {
        withObservationTracking {
            _ = model.isVisible
            _ = model.isHovering
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
        if panel?.isVisible == true { anchor(animated: false) }
    }

    // MARK: panel

    private func show() {
        let panel = panel ?? makePanel()
        self.panel = panel
        // Animate re-layouts (hover widen/narrow, mark added) so labels glide; first show is instant.
        anchor(animated: panel.isVisible)
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

    private func anchor(animated: Bool) {
        guard let panel, let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        // Width is hover-driven (constant); height follows the content (listening + mark count),
        // which is independent of hover, so fittingSize.height stays stable as we widen.
        let width = model.isHovering ? expandedWidth : collapsedWidth
        let height = panel.contentView?.fittingSize.height ?? 240
        let x: CGFloat = edge == .trailing
            ? visible.maxX - width - inset
            : visible.minX + inset
        let y = visible.midY - height / 2
        let frame = NSRect(x: x, y: y, width: width, height: height)
        if animated {
            // Glide the panel in step with the capsule's hover animation so labels never clip.
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.2
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().setFrame(frame, display: true)
            }
        } else {
            panel.setFrame(frame, display: true)
        }
    }
}
