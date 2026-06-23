import AppKit
import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import QuartzCore
import Vision

if CommandLine.arguments.contains("--selftest") {
    runSelfTest()
    exit(0)
}

// The capture hotkey is owned by the app process (#95), which
// spawns this sidecar only for the duration of a capture. So tracking auto-starts
// on launch and stops when the host kills the process.
private let writer = EventWriter()
private let tracker = HeadTracker(writer: writer)

NSApplication.shared.setActivationPolicy(.accessory)
startControlReader(tracker: tracker, writer: writer)
tracker.start()
RunLoop.main.run()
