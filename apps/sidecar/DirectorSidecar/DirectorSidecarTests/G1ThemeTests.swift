//
//  G1ThemeTests.swift
//  DirectorSidecarTests
//
//  Theme token drift guard (T-G1.0): Theme.resolve(.light/.dark) returns the design.md hex
//  for the key tokens, accent is appearance-independent gold, surfaces flip by mode, and the
//  override hook forces a mode. Colors are compared via their sRGB components.
//

import Testing
import SwiftUI
import AppKit
@testable import DirectorSidecar

private func rgba(_ color: Color) -> (r: Double, g: Double, b: Double, a: Double) {
    let ns = NSColor(color).usingColorSpace(.sRGB) ?? NSColor(color)
    return (Double(ns.redComponent), Double(ns.greenComponent), Double(ns.blueComponent), Double(ns.alphaComponent))
}

private func approx(_ a: Double, _ b: Double, _ tol: Double = 0.01) -> Bool { abs(a - b) <= tol }

@Test func themeAccentIsGoldInBothModes() {
    // #D4A018 == (0.831, 0.627, 0.094), appearance-independent.
    for theme in [Theme.resolve(.light), Theme.resolve(.dark)] {
        let c = rgba(theme.accent)
        #expect(approx(c.r, 0.831))
        #expect(approx(c.g, 0.627))
        #expect(approx(c.b, 0.094))
        #expect(approx(c.a, 1))
    }
}

@Test func themeTextPrimaryFlipsByMode() {
    let light = rgba(Theme.resolve(.light).textPrimary) // #1D1D1F
    #expect(approx(light.r, 0.114))
    #expect(approx(light.b, 0.122))
    let dark = rgba(Theme.resolve(.dark).textPrimary)   // #FFFFFF
    #expect(approx(dark.r, 1))
    #expect(approx(dark.g, 1))
    #expect(approx(dark.b, 1))
}

@Test func themeWindowFlipsAndDarkIsTranslucent() {
    let light = rgba(Theme.resolve(.light).window) // opaque #FFFFFF
    #expect(approx(light.r, 1))
    #expect(approx(light.a, 1))
    let dark = rgba(Theme.resolve(.dark).window)   // rgba(30,30,32,0.92)
    #expect(approx(dark.r, 30.0 / 255))
    #expect(approx(dark.b, 32.0 / 255))
    #expect(approx(dark.a, 0.92))
}

@Test func themeOverrideForcesMode() {
    // colorScheme=.light but the Preferences override forces dark → dark tokens.
    let forced = rgba(Theme.resolve(.light, override: .dark).textPrimary)
    #expect(approx(forced.r, 1))
}
