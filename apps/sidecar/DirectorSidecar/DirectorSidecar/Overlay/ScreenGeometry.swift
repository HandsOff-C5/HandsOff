//
//  ScreenGeometry.swift
//  DirectorSidecar
//
//  G5 coordinate conversion (load-bearing). The bridge `cursorPosition` space is virtual-desktop
//  px, top-left origin, y grows DOWN (surface.ts). AppKit/NSScreen is bottom-left, y grows UP. The
//  overlay flips Y around the PRIMARY screen's height; correct across displays incl. negative
//  offsets. The arrow TIP — not the image center — must land on the point.
//

import CoreGraphics

enum ScreenGeometry {
    /// Convert a contract point (top-left origin, y-down) to a Cocoa point (bottom-left, y-up).
    /// `primaryMaxY` is `NSScreen.screens[0].frame.maxY` (the (0,0)-origin / menu-bar screen).
    static func cocoaPoint(contractX: Double, contractY: Double, primaryMaxY: CGFloat) -> CGPoint {
        CGPoint(x: contractX, y: primaryMaxY - contractY)
    }

    /// Convert a contract rect (top-left origin, y-down) to a Cocoa rect (bottom-left, y-up). The
    /// Cocoa origin is the rect's BOTTOM-left, so y flips around the bottom edge (y + h).
    static func cocoaRect(
        x: Double, y: Double, w: Double, h: Double, primaryMaxY: CGFloat
    ) -> CGRect {
        CGRect(x: x, y: primaryMaxY - (y + h), width: w, height: h)
    }
}
