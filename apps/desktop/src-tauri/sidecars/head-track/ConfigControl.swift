import AppKit
import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import QuartzCore
import Vision

enum MovementMode: String {
    case edge
    case relative
}

struct HeadPointerConfig: Equatable {
    var movementMode: MovementMode
    var speed: Double
    var distanceToEdge: Double

    // speed raised 5→8, distanceToEdge halved 0.12→0.06 for snappier out-of-the-box feel
    static let `default` = HeadPointerConfig(movementMode: .edge, speed: 8, distanceToEdge: 0.06)

    var sanitized: HeadPointerConfig {
        HeadPointerConfig(
            movementMode: movementMode,
            speed: clamp(speed, 1...30),
            distanceToEdge: clamp(distanceToEdge, 0.02...0.4)
        )
    }
}

enum ControlCommand: Equatable {
    case config(HeadPointerConfig)
    case recenter
}

func doubleValue(_ value: Any?) -> Double? {
    if let value = value as? NSNumber {
        return value.doubleValue
    }
    if let value = value as? Double {
        return value
    }
    if let value = value as? String {
        return Double(value)
    }
    return nil
}

func parseControlCommand(_ line: String) -> ControlCommand? {
    guard let data = line.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let kind = object["kind"] as? String
    else {
        return nil
    }

    switch kind {
    case "recenter":
        return .recenter
    case "config":
        guard let headPointer = object["headPointer"] as? [String: Any] else { return nil }
        let modeRaw = headPointer["movementMode"] as? String ?? MovementMode.edge.rawValue
        guard let mode = MovementMode(rawValue: modeRaw) else { return nil }
        let config = HeadPointerConfig(
            movementMode: mode,
            speed: doubleValue(headPointer["speed"]) ?? HeadPointerConfig.default.speed,
            distanceToEdge: doubleValue(headPointer["distanceToEdge"]) ?? HeadPointerConfig.default.distanceToEdge
        )
        return .config(config.sanitized)
    default:
        return nil
    }
}
