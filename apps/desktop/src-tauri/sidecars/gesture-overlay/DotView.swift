import AppKit
import CoreGraphics
import Foundation

// The drawing surface for one display's overlay window. A flipped (top-left origin) NSView
// that renders any number of named cursor dots (one per hand) plus an optional calibration
// target ring. Top-left origin is what makes a CoreGraphics-local offset (from `locate`)
// land where the user expects with no vertical flip. Immediate-mode-ish: callers mutate
// state then the view redraws on the main thread.
final class DotView: NSView {
    private var cursors: [String: (point: NSPoint, color: NSColor)] = [:]
    private var target: NSPoint?

    override var isFlipped: Bool { true }

    // No layer here: assigning `layer` directly makes this a layer-HOSTING view, for which
    // AppKit never calls `draw(_:)`, so the dot/ring would never paint. The transparent host
    // window (`isOpaque = false`, clear `backgroundColor`) is what lets the bare `draw(_:)`
    // output float over the desktop — the same pattern funstuff's overlay uses.

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    func setCursor(_ id: String, at point: NSPoint, color: NSColor) {
        cursors[id] = (point, color)
        needsDisplay = true
    }

    func removeCursor(_ id: String) {
        guard cursors.removeValue(forKey: id) != nil else { return }
        needsDisplay = true
    }

    func clearCursors() {
        guard !cursors.isEmpty else { return }
        cursors.removeAll()
        needsDisplay = true
    }

    func setTarget(_ point: NSPoint?) {
        target = point
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        if let target {
            drawTarget(target)
        }
        for cursor in cursors.values {
            drawCursor(cursor.point, cursor.color)
        }
    }

    private func drawCursor(_ point: NSPoint, _ color: NSColor) {
        let radius: CGFloat = 13
        let rect = NSRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)
        color.withAlphaComponent(0.85).setFill()
        NSBezierPath(ovalIn: rect).fill()
        let outline = NSBezierPath(ovalIn: rect)
        outline.lineWidth = 2
        NSColor.white.setStroke()
        outline.stroke()
    }

    private func drawTarget(_ point: NSPoint) {
        let radius: CGFloat = 22
        let rect = NSRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)
        let ring = NSBezierPath(ovalIn: rect)
        ring.lineWidth = 4
        NSColor.systemYellow.withAlphaComponent(0.25).setFill()
        ring.fill()
        NSColor.systemYellow.setStroke()
        ring.stroke()
    }
}
