//
//  Theme.swift
//  DirectorSidecar
//
//  The shared design foundation for every Director surface (design.md §7 native mapping).
//  No view hard-codes a hex — every color/font/material/radius/spacing value reads from
//  `@Environment(\.theme)`. Accent + the four semantics are appearance-independent; surface
//  + text tokens flip by mode. Built once in G1, consumed by all gates.
//

import SwiftUI

struct Theme: Sendable {
    // MARK: Accent (appearance-independent)
    let accent: Color           // greenlight fill, running dot, active listening, focus ring, waveform
    let accentTint: Color       // hover; accent text on dark
    let accentPressed: Color    // pressed
    let accentWash: Color       // selected-referent fill, active-listening row tint
    let accentOnSurface: Color  // the only gold-as-text on a neutral surface (WCAG)
    let goldInk: Color          // label ink on solid-gold fills (white-on-gold forbidden)

    // MARK: Semantic (appearance-independent, Apple system values)
    let success: Color
    let warning: Color
    let danger: Color
    let info: Color

    // MARK: Surfaces & text (flip by mode)
    let canvas: Color
    let window: Color
    let sidebar: Color
    let card: Color
    let cardInset: Color
    let border: Color
    let separator: Color
    let textPrimary: Color
    let textSecondary: Color
    let textTertiary: Color
    let controlBg: Color
    let selectedBg: Color
    /// The hovered-row highlight in the menu dropdown — a neutral, clearly-visible selection fill
    /// (stronger than `controlBg`) so hover reads natively over glass, like a macOS menu item.
    let menuHighlight: Color
    /// Reduce-Transparency replacement for every glass surface — opaque window (light) /
    /// #1E1E1E (dark). Used when `accessibilityReduceTransparency` is on.
    let opaqueSurface: Color

    // MARK: Spacing (8pt grid) & shape
    let windowPadding: CGFloat = 20
    let elementGap: CGFloat = 12
    let stackGap: CGFloat = 8
    let iconBox: CGFloat = 16
    let menuWidth: CGFloat = 262
    let sidebarWidth: CGFloat = 240
    let toolbarHeight: CGFloat = 52
    let inspectorWidth: CGFloat = 290
    let rowHeight: CGFloat = 30
    let hudWidth: CGFloat = 300
    let hudInset: CGFloat = 28
    let microHudWidth: CGFloat = 232
    // Radii — always `.continuous`.
    let radiusWindow: CGFloat = 12
    let radiusCard: CGFloat = 10
    let radiusControl: CGFloat = 6
    let radiusChip: CGFloat = 5

    // MARK: Typography (SF Pro / SF Mono)
    let body = Font.system(size: 13)                                   // 13px body floor
    let sectionTitle = Font.system(size: 15, weight: .semibold)        // menu header, panel titles
    let largeTitle = Font.system(size: 24, weight: .semibold)          // window/onboarding titles
    let sectionLabel = Font.system(size: 11, weight: .semibold)        // UPPERCASE + tracking applied at call site
    let mono = Font.system(size: 11, design: .monospaced)              // timers, counts, IDs
    let kbd = Font.system(size: 10, design: .monospaced)               // "⇧⌘M", "hold fn"

    // MARK: Motion
    /// Standard easing — `.timingCurve(0.16, 1, 0.3, 1, duration: 0.35)`.
    var standardMotion: Animation { .timingCurve(0.16, 1, 0.3, 1, duration: 0.35) }
    /// Quick hover/selection — ~0.2s on the same curve.
    var quickMotion: Animation { .timingCurve(0.16, 1, 0.3, 1, duration: 0.2) }

    // MARK: Resolution

    /// Resolve the theme for a color scheme, honoring an optional explicit override (the
    /// future Preferences light/dark toggle — present API, deferred UI).
    static func resolve(_ scheme: ColorScheme, override: ColorScheme? = nil) -> Theme {
        (override ?? scheme) == .dark ? .dark : .light
    }

    static let light = Theme(
        accent: Color(hex: 0xD4A018),
        accentTint: Color(hex: 0xE6C265),
        accentPressed: Color(hex: 0xA87D10),
        accentWash: Color(hex: 0xD4A018, alpha: 0.14),
        accentOnSurface: Color(hex: 0x8A6D0F),
        goldInk: Color(hex: 0x1D1D1F),
        success: Color(hex: 0x32D75F),
        warning: Color(hex: 0xFF9F0A),
        danger: Color(hex: 0xFF453A),
        info: Color(hex: 0x5E5CE6),
        canvas: Color(hex: 0xECECEE),
        window: Color(hex: 0xFFFFFF),
        sidebar: Color(hex: 0xF4F4F6),
        card: Color(hex: 0xFFFFFF),
        cardInset: Color(hex: 0xF2F2F4),
        border: Color(hex: 0x000000, alpha: 0.12),
        separator: Color(hex: 0x000000, alpha: 0.08),
        textPrimary: Color(hex: 0x1D1D1F),
        textSecondary: Color(hex: 0x515154),
        textTertiary: Color(hex: 0x6E6E73),
        controlBg: Color(hex: 0x000000, alpha: 0.05),
        selectedBg: Color(hex: 0xD4A018, alpha: 0.14),
        menuHighlight: Color(hex: 0x000000, alpha: 0.07),
        opaqueSurface: Color(hex: 0xFFFFFF)
    )

    static let dark = Theme(
        accent: Color(hex: 0xD4A018),
        accentTint: Color(hex: 0xE6C265),
        accentPressed: Color(hex: 0xA87D10),
        accentWash: Color(hex: 0xD4A018, alpha: 0.14),
        accentOnSurface: Color(hex: 0xE6C265),
        goldInk: Color(hex: 0x1D1D1F),
        success: Color(hex: 0x32D75F),
        warning: Color(hex: 0xFF9F0A),
        danger: Color(hex: 0xFF453A),
        info: Color(hex: 0x5E5CE6),
        canvas: Color(hex: 0x0D0F13),
        window: Color(hex: 0x1E1E20, alpha: 0.92),
        sidebar: Color(hex: 0x18181A, alpha: 0.60),
        card: Color(hex: 0x2C2C2E, alpha: 0.55),
        cardInset: Color(hex: 0x000000, alpha: 0.22),
        border: Color(hex: 0xFFFFFF, alpha: 0.12),
        separator: Color(hex: 0xFFFFFF, alpha: 0.09),
        textPrimary: Color(hex: 0xFFFFFF),
        textSecondary: Color(hex: 0xFFFFFF, alpha: 0.66),
        textTertiary: Color(hex: 0xFFFFFF, alpha: 0.46),
        controlBg: Color(hex: 0xFFFFFF, alpha: 0.06),
        selectedBg: Color(hex: 0xD4A018, alpha: 0.16),
        menuHighlight: Color(hex: 0xFFFFFF, alpha: 0.10),
        opaqueSurface: Color(hex: 0x1E1E1E)
    )
}

private struct ThemeKey: EnvironmentKey {
    static let defaultValue = Theme.light
}

extension EnvironmentValues {
    var theme: Theme {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
    }
}
