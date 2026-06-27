//
//  DirectorMark.swift
//  DirectorSidecar
//
//  The shared brand visuals used by both the right-edge rail (micro) and the dashboard agent cards
//  (larger): the status-tinted Director mark (ring + arrowhead) and the listening waveform. One
//  source of truth so the two surfaces read as the same system at different sizes.
//

import SwiftUI

/// The brand agent mark — the ONE gold Director cursor (`DirectorCursorGlyph`, the same glyph the G5
/// following cursor draws) inside a status frame. The cursor is ALWAYS gold; the ring + motion carry
/// state, the way the app icon's brackets frame the same gold cursor, so the cursor reads identically
/// on every surface:
///   • running         → gold ring + a pulsing gold halo (radar ping); the cursor stays static
///   • needs greenlight → ring breathes white ↔ gray (waiting on a human in the loop, like a hold)
///   • complete         → gold ring + gold ✓ badge (done is gold, not green)
///   • paused           → the Open-Director gray ring + a dimmed cursor, no motion (held)
/// Scales from the rail's 36pt up.
struct DirectorMark: View {
    let status: ExecutionStatus
    var paused: Bool = false
    var size: CGFloat = 36
    var animated: Bool = true

    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isRunning: Bool { status == .running || status == .queued }
    private var isDone: Bool { status == .succeeded || status == .failed || status == .rejected }
    private var needsGreenlight: Bool { status == .blocked }

    private enum Mode { case running, needsGreenlight, done, paused, idle }
    private var mode: Mode {
        if paused { return .paused }
        if isDone { return .done }
        if needsGreenlight { return .needsGreenlight }
        if isRunning { return .running }
        return .idle
    }

    /// Whether the running cursor sways + the greenlight ring breathes.
    private var motionOn: Bool { animated && !reduceMotion }
    private var ringWidth: CGFloat { size * 0.042 }
    /// The arrowhead's visual mass sits low-right of its frame; nudge it down-right to read centered.
    private var glyphBase: CGSize { CGSize(width: size * 0.0248, height: size * 0.0405) }

    var body: some View {
        ZStack {
            frame
            glyph
            if mode == .done { doneBadge }
        }
        .frame(width: size, height: size)
    }

    // MARK: frame (disc + ring) — carries status; never recolors the cursor

    @ViewBuilder private var frame: some View {
        switch mode {
        case .done:
            disc(theme.accent.opacity(0.14), ring: theme.accent)
        case .paused:
            // The Open-Director control's gray ring, for continuity with that affordance.
            disc(theme.controlBg, ring: theme.border)
        case .needsGreenlight:
            // The ring breathes white ↔ the Open-Director gray: an agent waiting on a human.
            disc(theme.textPrimary.opacity(0.05), ring: .clear)
            if motionOn {
                // TimelineView-driven (continuous sin → opacity) so the rail's hover-widen
                // transaction can't capture/freeze the breathe, and the loop is seamless.
                TimelineView(.animation) { context in
                    let t = context.date.timeIntervalSinceReferenceDate
                    let p = (sin(t / 1.4 * 2 * .pi) + 1) / 2          // 0…1, seamless
                    Circle().strokeBorder(theme.textPrimary, lineWidth: ringWidth)
                        .frame(width: size, height: size)
                        .opacity(0.12 + (1.0 - 0.12) * p)             // gray ↔ white
                }
            } else {
                Circle().strokeBorder(theme.textPrimary, lineWidth: ringWidth)
                    .frame(width: size, height: size).opacity(0.5)
            }
        case .running:
            // Gold ring + a pulsing gold halo (the radar-ping). TimelineView-driven so the rail's
            // hover-widen transaction can't capture/freeze it.
            if motionOn {
                TimelineView(.animation) { context in
                    let p = (context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.6)) / 1.6
                    Circle().stroke(theme.accent, lineWidth: ringWidth)
                        .frame(width: size, height: size)
                        .scaleEffect(1 + 0.5 * p)
                        .opacity(0.6 * (1 - p))
                }
            }
            disc(theme.accent.opacity(0.14), ring: theme.accent)
        case .idle:
            disc(theme.accent.opacity(0.14), ring: theme.accent)
        }
    }

    private func disc(_ fill: Color, ring: Color) -> some View {
        Circle().fill(fill)
            .overlay(Circle().strokeBorder(ring, lineWidth: ringWidth))
            .frame(width: size, height: size)
    }

    // MARK: glyph — the one gold cursor, always static; dims while paused

    private var glyph: some View {
        DirectorCursorGlyph(height: size * 0.45)
            .offset(x: glyphBase.width, y: glyphBase.height)
            .opacity(mode == .paused ? 0.5 : 1)
    }

    private var doneBadge: some View {
        Circle().fill(theme.accent)
            .frame(width: size * 0.36, height: size * 0.36)
            .overlay(Image(systemName: "checkmark").font(.system(size: size * 0.2, weight: .bold)).foregroundStyle(.white))
            .offset(x: size * 0.34, y: size * 0.34)
    }
}

/// Gold equalizer bars pulsing like a live audio waveform — the listening / agent-working signal.
/// No native waveform exists, so this is the one custom shape, shared by the rail pip and the cards.
/// TimelineView-driven (continuous time → height) so a parent `.animation` transaction (the rail's
/// hover widen) can't capture the loop and freeze the bars at full height.
struct ListeningWaveform: View {
    var tint: Color? = nil
    var barCount: Int = 7
    var barWidth: CGFloat = 2
    var maxHeight: CGFloat = 18
    var minHeight: CGFloat = 8
    var spacing: CGFloat = 2

    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let color = tint ?? theme.accent
        TimelineView(.animation(paused: reduceMotion)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: spacing) {
                ForEach(0..<barCount, id: \.self) { i in
                    Capsule().fill(color)
                        .frame(width: barWidth, height: height(bar: i, at: t))
                }
            }
        }
        .frame(width: CGFloat(barCount) * barWidth + CGFloat(barCount - 1) * spacing, height: maxHeight)
        .accessibilityHidden(true)
    }

    private func height(bar i: Int, at t: TimeInterval) -> CGFloat {
        guard !reduceMotion else { return (minHeight + maxHeight) / 2 }
        let phase = Double(i) * 0.42 // gentle per-bar offset so more bars read as one smooth wave
        let norm = (sin((t / 0.9 + phase) * 2 * .pi) + 1) / 2 // 0…1, staggered per bar
        return minHeight + (maxHeight - minHeight) * norm
    }
}

/// The brand cursor glyph — the ONE Director cursor, styled once and reused everywhere: the gold
/// `DirectorArrow` with a white keyline and a soft drop shadow. ALWAYS gold — never recolored per
/// status; surfaces that show agent state (rail pips, dashboard cards) frame this glyph with a
/// status ring/halo/badge, exactly as the app icon frames the same gold cursor with brackets. Used
/// by `DirectorMark` (rail + dashboard) and the G5 following + agent cursors
/// (`ReticleOverlayView`). This is the single definition of the cursor's look — do not restyle it
/// per surface. `height` is the glyph height; width follows the canonical 51:54 ratio.
struct DirectorCursorGlyph: View {
    var height: CGFloat = 23
    @Environment(\.theme) private var theme

    var body: some View {
        DirectorArrow()
            .fill(theme.accent)
            .overlay(DirectorArrow().stroke(.white, lineWidth: height * 0.055))
            .frame(width: height * 51 / 54, height: height)
            .shadow(color: .black.opacity(0.4), radius: height * 0.0365, y: height * 0.051)
    }
}

/// The Director arrowhead geometry — the SINGLE source of truth for the brand cursor shape.
/// Geometrically identical to the app icon, `Menu-Icon.svg`, and `Agent-Cursor.svg` (same
/// four-vertex kite, no system-pointer tail). Draw it through `DirectorCursorGlyph` so the styling
/// stays consistent; do not add a second arrowhead shape. Normalized from its 51×54 viewBox so it
/// scales to any frame.
struct DirectorArrow: Shape {
    func path(in rect: CGRect) -> Path {
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x / 51 * rect.width, y: rect.minY + y / 54 * rect.height)
        }
        var path = Path()
        path.move(to: p(4, 2))
        path.addLine(to: p(14.7986, 47.2052))
        path.addLine(to: p(23.5954, 25.3528))
        path.addLine(to: p(46.6433, 20.4843))
        path.closeSubpath()
        return path
    }
}
