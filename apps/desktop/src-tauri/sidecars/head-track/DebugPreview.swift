import AppKit
import CoreGraphics
import Foundation

// A movable, normal (NOT click-through) debug window that shows the head tracker's
// own camera frame with the landmarks it reads drawn on top: the face box, the eye
// midpoint, the nose point, the eye→nose offset, plus a text readout of the live
// signal. Lets the user SEE what "gaze" tracking actually perceives and why the dot
// lands where it does. Drawn from the already-captured frame — it never opens its
// own camera (that would contend with the tracking session).
//
// All methods must be called on the main thread (HeadTracker dispatches there).

final class DebugPreviewView: NSView {
    var image: CGImage?
    var signal: HeadSignal?
    var neutralNoseOffset: CGPoint?
    var cursor: CGPoint?

    // Bottom-left origin (y up), matching Vision's normalized space, so landmark
    // mapping is a straight nx/ny → pixels (with a horizontal flip for the selfie view).
    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let width = bounds.width
        let height = bounds.height

        ctx.setFillColor(NSColor.black.cgColor)
        ctx.fill(bounds)

        // The tracker runs Vision with .upMirrored, so its coords are in the mirrored
        // (selfie) frame. Draw the image mirrored too so the overlays line up.
        if let image {
            ctx.saveGState()
            ctx.translateBy(x: width, y: 0)
            ctx.scaleBy(x: -1, y: 1)
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            ctx.restoreGState()
        }

        guard let signal else {
            drawReadout(ctx: ctx, lines: ["no face detected"], width: width, height: height)
            return
        }

        // Vision (.upMirrored) already returns coords in the mirrored (selfie) space —
        // the SAME space as the mirror-drawn image above. So map nx/ny straight to
        // pixels; do NOT flip again (the old (1-x) double-mirrored it, putting the box
        // on the opposite side from the face).
        func toView(_ point: CGPoint) -> CGPoint {
            CGPoint(x: point.x * width, y: point.y * height)
        }

        let box = signal.faceBox
        let boxRect = CGRect(
            x: box.minX * width,
            y: box.minY * height,
            width: box.width * width,
            height: box.height * height
        )
        ctx.setStrokeColor(NSColor.systemGreen.cgColor)
        ctx.setLineWidth(2)
        ctx.stroke(boxRect)

        // Reconstruct the nose point from the signal: noseOffset = (nose - eye) / eyeDist.
        let eye = signal.eyeMidpoint
        let nose = CGPoint(
            x: eye.x + signal.noseOffset.x * signal.eyeDistance,
            y: eye.y + signal.noseOffset.y * signal.eyeDistance
        )
        let eyeView = toView(eye)
        let noseView = toView(nose)

        // Eye → nose offset vector.
        ctx.setStrokeColor(NSColor.systemYellow.cgColor)
        ctx.setLineWidth(2)
        ctx.beginPath()
        ctx.move(to: eyeView)
        ctx.addLine(to: noseView)
        ctx.strokePath()

        drawDot(ctx: ctx, at: eyeView, color: .systemBlue)
        drawDot(ctx: ctx, at: noseView, color: .systemRed)

        let neutral = neutralNoseOffset
        let cursorText = cursor.map { String(format: "(%.0f, %.0f)", $0.x, $0.y) } ?? "—"
        drawReadout(
            ctx: ctx,
            lines: [
                String(format: "noseOffset  x=%.3f  y=%.3f", signal.noseOffset.x, signal.noseOffset.y),
                String(format: "yaw=%@  pitch=%@", fmt(signal.yaw), fmt(signal.pitch)),
                String(format: "confidence=%.2f", signal.confidence),
                "neutral nose  " + (neutral.map { String(format: "x=%.3f  y=%.3f", $0.x, $0.y) } ?? "(not set)"),
                "cursor  " + cursorText,
            ],
            width: width,
            height: height
        )
    }

    private func fmt(_ value: Double?) -> String {
        guard let value else { return "nil" }
        return String(format: "%.3f", value)
    }

    private func drawDot(ctx: CGContext, at point: CGPoint, color: NSColor) {
        ctx.setFillColor(color.cgColor)
        ctx.fillEllipse(in: CGRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8))
    }

    private func drawReadout(ctx: CGContext, lines: [String], width: CGFloat, height: CGFloat) {
        let text = lines.joined(separator: "\n")
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let lineHeight: CGFloat = 15
        let boxHeight = CGFloat(lines.count) * lineHeight + 8
        let rect = CGRect(x: 6, y: height - boxHeight - 6, width: width - 12, height: boxHeight)
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.55).cgColor)
        ctx.fill(rect)
        (text as NSString).draw(
            in: rect.insetBy(dx: 4, dy: 4),
            withAttributes: attributes
        )
    }
}

final class DebugPreviewWindow {
    private var window: NSWindow?
    private var view: DebugPreviewView?

    private func ensureWindow() {
        guard window == nil else { return }
        let frame = NSRect(x: 120, y: 120, width: 480, height: 360)
        let win = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        win.title = "HandsOff — head tracking debug"
        win.isReleasedWhenClosed = false
        let content = DebugPreviewView(frame: NSRect(origin: .zero, size: frame.size))
        content.autoresizingMask = [.width, .height]
        win.contentView = content
        window = win
        view = content
    }

    func update(image: CGImage, signal: HeadSignal, neutralNoseOffset: CGPoint?, cursor: CGPoint?) {
        ensureWindow()
        view?.image = image
        view?.signal = signal
        view?.neutralNoseOffset = neutralNoseOffset
        view?.cursor = cursor
        view?.needsDisplay = true
    }

    func show() {
        ensureWindow()
        window?.orderFrontRegardless()
    }

    func hide() {
        window?.orderOut(nil)
    }
}
