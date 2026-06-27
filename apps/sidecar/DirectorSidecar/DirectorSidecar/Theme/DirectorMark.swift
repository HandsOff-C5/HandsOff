//
//  DirectorMark.swift
//  DirectorSidecar
//
//  The shared brand visuals used by both the right-edge rail (micro) and the dashboard agent cards
//  (larger): the status-tinted Director mark (ring + arrowhead) and the listening waveform. One
//  source of truth so the two surfaces read as the same system at different sizes.
//

import SwiftUI

/// The brand agent mark — a status-tinted ring with the Director arrowhead. Gold = running (soft
/// pulsing halo), amber = needs greenlight, green + ✓ = complete. Scales from the rail's 36pt up.
struct DirectorMark: View {
    let status: ExecutionStatus
    /// Paused agents keep the static ring + arrowhead but drop the pulsing halo — the halo means
    /// "actively working".
    var paused: Bool = false
    var size: CGFloat = 36
    var animated: Bool = true

    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isRunning: Bool { status == .running || status == .queued }
    private var isDone: Bool { status == .succeeded || status == .failed || status == .rejected }
    private var needsGreenlight: Bool { status == .blocked }
    private var color: Color {
        if isDone { return theme.success }
        if needsGreenlight { return theme.warning }
        return theme.accent
    }

    var body: some View {
        ZStack {
            // Running (and not paused) → a soft pulsing halo (radar-ping). TimelineView-driven so a
            // parent .animation transaction (e.g. the rail's hover widen) can't capture/freeze it.
            if isRunning, !paused, animated, !reduceMotion {
                TimelineView(.animation) { context in
                    let p = (context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.6)) / 1.6
                    Circle().stroke(theme.accent, lineWidth: size * 0.042)
                        .frame(width: size, height: size)
                        .scaleEffect(1 + 0.5 * p)
                        .opacity(0.6 * (1 - p))
                }
            }
            Circle().fill(color.opacity(0.14))
                .overlay(Circle().strokeBorder(color, lineWidth: size * 0.042))
                .frame(width: size, height: size)
            // Brand arrowhead — white keyline under a status-colored fill.
            DirectorArrow().stroke(.white, lineWidth: size * 0.055)
                .background(DirectorArrow().fill(color))
                .frame(width: size * 0.42, height: size * 0.45)
            if isDone {
                Circle().fill(theme.success)
                    .frame(width: size * 0.36, height: size * 0.36)
                    .overlay(Image(systemName: "checkmark").font(.system(size: size * 0.2, weight: .bold)).foregroundStyle(.white))
                    .offset(x: size * 0.34, y: size * 0.34)
            }
        }
        .frame(width: size, height: size)
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

/// The Director arrowhead from the design system (Menu-Icon / agent cursor), normalized from its
/// 51×54 viewBox so it scales to any frame.
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
