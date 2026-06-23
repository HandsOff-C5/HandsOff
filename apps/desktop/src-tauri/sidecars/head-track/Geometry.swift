import AppKit
import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import QuartzCore
import Vision

func clamp(_ value: Double, _ range: ClosedRange<Double>) -> Double {
    min(max(value, range.lowerBound), range.upperBound)
}

func containsInclusive(_ rect: CGRect, _ point: CGPoint) -> Bool {
    point.x >= rect.minX && point.x <= rect.maxX && point.y >= rect.minY && point.y <= rect.maxY
}

func squaredDistance(_ point: CGPoint, to rect: CGRect) -> Double {
    let x = clamp(point.x, rect.minX...rect.maxX)
    let y = clamp(point.y, rect.minY...rect.maxY)
    let dx = point.x - x
    let dy = point.y - y
    return dx * dx + dy * dy
}

func clampIntoRealScreen(_ point: CGPoint, screens: [CGRect]) -> CGPoint {
    guard !screens.isEmpty else { return point }
    if screens.contains(where: { containsInclusive($0, point) }) {
        return point
    }
    let nearest = screens.min { squaredDistance(point, to: $0) < squaredDistance(point, to: $1) }!
    return CGPoint(
        x: clamp(point.x, nearest.minX...nearest.maxX),
        y: clamp(point.y, nearest.minY...nearest.maxY)
    )
}

func unionRect(_ screens: [CGRect]) -> CGRect? {
    screens.reduce(nil as CGRect?) { partial, rect in
        guard let partial else { return rect }
        return partial.union(rect)
    }
}

func defaultPointerPoint(screens: [CGRect]) -> CGPoint? {
    guard let union = unionRect(screens), union.width > 0, union.height > 0 else {
        return nil
    }
    return clampIntoRealScreen(CGPoint(x: union.midX, y: union.midY), screens: screens)
}

func center(_ rect: CGRect) -> CGPoint {
    CGPoint(x: rect.midX, y: rect.midY)
}

func distance(_ a: CGPoint, _ b: CGPoint) -> Double {
    let dx = a.x - b.x
    let dy = a.y - b.y
    return sqrt(dx * dx + dy * dy)
}

func blend(_ a: CGPoint, _ b: CGPoint, alpha: Double) -> CGPoint {
    CGPoint(x: a.x + (b.x - a.x) * alpha, y: a.y + (b.y - a.y) * alpha)
}

func area(_ rect: CGRect) -> Double {
    max(0, rect.width) * max(0, rect.height)
}

func intersectionOverUnion(_ a: CGRect, _ b: CGRect) -> Double {
    let intersection = a.intersection(b)
    let union = area(a) + area(b) - area(intersection)
    guard union > 0 else { return 0 }
    return area(intersection) / union
}

