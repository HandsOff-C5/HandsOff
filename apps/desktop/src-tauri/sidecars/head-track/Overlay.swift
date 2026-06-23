import AppKit
import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import QuartzCore
import Vision

final class GoldenCursorOverlay {
    private let size: CGFloat = 34
    private lazy var panel: NSPanel = {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: size, height: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .screenSaver
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let view = NSView(frame: NSRect(x: 0, y: 0, width: size, height: size))
        view.wantsLayer = true
        if let layer = view.layer {
            let gold = NSColor(calibratedRed: 1.0, green: 0.73, blue: 0.2, alpha: 1.0).cgColor
            layer.backgroundColor = NSColor(calibratedRed: 1.0, green: 0.83, blue: 0.32, alpha: 0.9).cgColor
            layer.cornerRadius = size / 2
            layer.shadowColor = gold
            layer.shadowOpacity = 0.95
            layer.shadowOffset = .zero
            layer.shadowRadius = 18
            layer.borderColor = NSColor.white.withAlphaComponent(0.8).cgColor
            layer.borderWidth = 1
        }
        panel.contentView = view
        return panel
    }()

    func show(at point: CGPoint) {
        let frame = NSRect(x: point.x - size / 2, y: point.y - size / 2, width: size, height: size)
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
    }
}
