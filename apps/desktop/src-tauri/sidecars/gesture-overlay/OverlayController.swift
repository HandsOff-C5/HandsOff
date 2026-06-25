import AppKit
import CoreGraphics
import Foundation

// The overlay controller. Owns one transparent, click-through, `.screenSaver`-level
// window PER display so a cursor dot can be drawn anywhere across a multi-monitor
// desktop (including over fullscreen apps). It is driven by line commands on stdin so the
// Rust host can move the cursor every frame without IPC overhead, and replies to a
// `DISPLAYS` query on stdout so the host calibrates against the SAME CoreGraphics layout
// the windows are built from — eliminating any coordinate-space mismatch between where
// the dot is drawn and where calibration targets are generated.

private func color(for cursorID: String) -> NSColor {
    cursorID == "left"
        ? NSColor(calibratedRed: 0.35, green: 0.62, blue: 1.0, alpha: 1.0)
        : NSColor(calibratedRed: 0.30, green: 0.95, blue: 0.55, alpha: 1.0)
}

final class OverlayController: NSObject, NSApplicationDelegate {
    private var displays: [DisplayRect] = []
    private var windows: [NSWindow] = []
    private var viewsByDisplay: [Int: DotView] = [:]

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        buildDisplays()
        buildWindows()
        startStdinReader()
        // Emit the display layout once at launch so the host can start pointing immediately.
        // `gesture_overlay_start` awaits this line before resolving; without it the host hangs
        // and the camera detection loop never starts.
        emitDisplays()
    }

    // CoreGraphics is the authoritative source for the global (top-left origin) layout;
    // NSScreen is used only to create the windows, bridged via the NSScreenNumber device
    // key which yields the matching CGDirectDisplayID.
    private func buildDisplays() {
        displays = enumerateDisplays()
    }

    private func buildWindows() {
        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            else { continue }
            let displayID = Int(number.uint32Value)

            let window = NSWindow(
                contentRect: screen.frame,
                styleMask: .borderless,
                backing: .buffered,
                defer: false
            )
            window.isOpaque = false
            window.backgroundColor = .clear
            window.ignoresMouseEvents = true
            window.level = .screenSaver
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            window.hasShadow = false

            let view = DotView(frame: NSRect(origin: .zero, size: screen.frame.size))
            window.contentView = view
            window.orderFrontRegardless()

            windows.append(window)
            viewsByDisplay[displayID] = view
        }
    }

    private func startStdinReader() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            while let line = readLine(strippingNewline: true) {
                self?.handle(command: line)
            }
            // stdin closed → host is gone. Quit so we never orphan transparent windows.
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    private func handle(command line: String) {
        let parts = line.split(separator: " ").map(String.init)
        guard let verb = parts.first else { return }
        DispatchQueue.main.async {
            switch verb {
            case "MOVE":
                // MOVE <cursorId> <globalX> <globalY>
                guard parts.count >= 4,
                      let gx = Double(parts[2]),
                      let gy = Double(parts[3]) else { return }
                self.placeCursor(parts[1], globalX: gx, globalY: gy)
            case "TARGET":
                // TARGET <globalX> <globalY>
                guard parts.count >= 3,
                      let gx = Double(parts[1]),
                      let gy = Double(parts[2]) else { return }
                self.placeTarget(globalX: gx, globalY: gy)
            case "UNTARGET":
                self.clearTarget()
            case "CLEAR":
                if parts.count >= 2 { self.removeCursor(parts[1]) } else { self.clearAll() }
            case "DISPLAYS":
                self.emitDisplays()
            case "QUIT":
                NSApp.terminate(nil)
            default:
                break
            }
        }
    }

    // A cursor can cross a monitor boundary, so it is removed from every window then placed
    // on the single window for the display the global point resolves to.
    private func placeCursor(_ id: String, globalX: Double, globalY: Double) {
        for view in viewsByDisplay.values { view.removeCursor(id) }
        guard let loc = locate(globalX, globalY, displays: displays),
              let view = viewsByDisplay[loc.displayID] else { return }
        view.setCursor(id, at: NSPoint(x: loc.localX, y: loc.localY), color: color(for: id))
    }

    private func placeTarget(globalX: Double, globalY: Double) {
        guard let loc = locate(globalX, globalY, displays: displays),
              let view = viewsByDisplay[loc.displayID] else { return }
        // A target ring can only be on one display at a time; clear it everywhere first.
        for other in viewsByDisplay.values { other.setTarget(nil) }
        view.setTarget(NSPoint(x: loc.localX, y: loc.localY))
    }

    private func clearTarget() {
        for view in viewsByDisplay.values { view.setTarget(nil) }
    }

    private func removeCursor(_ id: String) {
        for view in viewsByDisplay.values { view.removeCursor(id) }
    }

    private func clearAll() {
        for view in viewsByDisplay.values {
            view.clearCursors()
            view.setTarget(nil)
        }
    }

    private func emitDisplays() {
        let payload: [[String: Any]] = displays.map { d in
            [
                "id": String(d.id),
                "isMain": d.isMain,
                "x": d.x,
                "y": d.y,
                "width": d.width,
                "height": d.height,
            ]
        }
        guard let data = try? JSONSerialization.data(
            withJSONObject: ["kind": "displays", "displays": payload]
        ) else { return }
        var line = data
        line.append(0x0A)
        FileHandle.standardOutput.write(line)
    }
}
