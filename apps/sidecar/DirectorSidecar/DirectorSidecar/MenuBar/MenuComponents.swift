//
//  MenuComponents.swift
//  DirectorSidecar
//
//  Menu-bar dropdown rows + the status-item label (G1 §SwiftUI component spec). Rows are plain
//  buttons with custom hover; timers tick via TimelineView. Honors Reduce Motion.
//

import SwiftUI
import AppKit

/// The status-bar item: the brand template glyph + a readiness dot overlay (dot only when not
/// ready — a calm bar). Readiness is the dot, never a recolor of the template glyph.
struct MenuBarLabel: View {
    let readiness: ReadinessLevel
    @Environment(\.theme) private var theme

    var body: some View {
        // The Template-Image asset, explicitly sized so the status item is visible (a MenuBarExtra
        // label needs a concrete frame). Template-rendered → auto-tints to the menu-bar appearance.
        Image("Template-Image")
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .frame(width: 18, height: 18)
            .overlay(alignment: .topTrailing) {
                if readiness != .ready {
                    Circle()
                        .fill(theme.color(for: readiness))
                        .frame(width: 6, height: 6)
                        .offset(x: 4, y: -3)
                }
            }
            .accessibilityLabel("Director")
            .accessibilityValue(readiness.spoken)
    }
}
// The dropdown rows (MenuActionRow / SessionRow / EmptyAgentsRow) were retired when the status menu
// moved to the native `.menu` style — macOS renders the items now, so only the status-item label
// above remains custom.
