import AppKit
import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import QuartzCore
import Vision

func epochMillis() -> Int64 {
    Int64((Date().timeIntervalSince1970 * 1000).rounded())
}

func startEvent(ts: Int64 = epochMillis()) -> [String: Any] {
    ["kind": "start", "ts": ts]
}

func stopEvent(ts: Int64 = epochMillis()) -> [String: Any] {
    ["kind": "stop", "ts": ts]
}

func pointEvent(
    x: Double,
    y: Double,
    yaw: Double?,
    pitch: Double?,
    confidence: Double,
    ts: Int64 = epochMillis()
) -> [String: Any] {
    [
        "kind": "point",
        "x": x,
        "y": y,
        "yaw": yaw ?? NSNull(),
        "pitch": pitch ?? NSNull(),
        "confidence": clamp(confidence, 0...1),
        "ts": ts,
    ]
}

func errorEvent(message: String, ts: Int64 = epochMillis()) -> [String: Any] {
    ["kind": "error", "message": message, "ts": ts]
}

final class EventWriter {
    private let lock = NSLock()

    func start() {
        emit(startEvent())
    }

    func stop() {
        emit(stopEvent())
    }

    func point(x: Double, y: Double, yaw: Double?, pitch: Double?, confidence: Double) {
        emit(pointEvent(x: x, y: y, yaw: yaw, pitch: pitch, confidence: confidence))
    }

    func error(_ message: String) {
        emit(errorEvent(message: message))
    }

    private func emit(_ object: [String: Any]) {
        lock.lock()
        defer { lock.unlock() }

        do {
            let data = try JSONSerialization.data(withJSONObject: object, options: [])
            if let line = String(data: data, encoding: .utf8) {
                fputs(line, stdout)
                fputc(10, stdout)
                fflush(stdout)
            }
        } catch {
            fputs("head-track: failed to encode stdout event: \(error)\n", stderr)
        }
    }
}

