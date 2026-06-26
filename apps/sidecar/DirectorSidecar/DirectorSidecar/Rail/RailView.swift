//
//  RailView.swift
//  DirectorSidecar
//
//  The Right-edge rail capsule (design: right-edge-rail-spec.md). Super-native: a real
//  NSVisualEffectView `.hudWindow` glass behind a SwiftUI `Capsule`, SF Symbols + standard
//  controls, gold the only brand color. Custom only where macOS has no equivalent: the LIVE
//  waveform bars and the brand cursor arrowhead. Top→bottom: LIVE pip (listening) · hairline ·
//  agent cursor-marks · hairline · Open-Home button.
//

import SwiftUI

struct RailView: View {
    let model: RailModel
    var onExpand: () -> Void

    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        VStack(spacing: theme.elementGap) {
            if model.isListening {
                LivePip()
                hairline
            }
            if !model.marks.isEmpty {
                VStack(spacing: theme.elementGap) {
                    ForEach(model.marks) { AgentMark(session: $0) }
                }
                hairline
            }
            ExpandButton(action: onExpand)
        }
        .padding(.vertical, theme.elementGap)
        .padding(.horizontal, theme.stackGap)
        .frame(minWidth: 52)
        .background {
            if reduceTransparency {
                Capsule().fill(theme.opaqueSurface)
            } else {
                VisualEffectBlur(.hudWindow, blending: .behindWindow).clipShape(Capsule())
            }
        }
        .overlay(Capsule().strokeBorder(theme.border, lineWidth: 1))
        .fixedSize()
        .animation(theme.standardMotion, value: model.isListening)
        .animation(theme.standardMotion, value: model.marks)
    }

    private var hairline: some View {
        Rectangle().fill(theme.separator).frame(width: 20, height: 1)
    }
}

// MARK: - LIVE pip (waveform + label)

/// Shown only while listening — the minimal echo of the wide Listening HUD's "LISTENING" treatment.
private struct LivePip: View {
    var body: some View {
        Waveform()
            .accessibilityElement()
            .accessibilityLabel("Listening")
    }
}

/// Four gold bars pulsing like an audio equalizer. No native waveform exists → custom (minimal).
private struct Waveform: View {
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var animating = false

    private static let barCount = 4

    var body: some View {
        HStack(alignment: .center, spacing: 2.5) {
            ForEach(0..<Self.barCount, id: \.self) { i in
                Capsule()
                    .fill(theme.accent)
                    .frame(width: 3, height: animating && !reduceMotion ? 18 : 8)
                    .animation(
                        reduceMotion ? nil
                        : .easeInOut(duration: 0.45).repeatForever(autoreverses: true).delay(Double(i) * 0.13),
                        value: animating
                    )
            }
        }
        .frame(width: 20, height: 18)
        .onAppear { animating = true }
        .accessibilityHidden(true)
    }
}

// MARK: - Agent cursor-mark

/// One running agent as the brand cursor in a status-tinted ring: gold (running, pulsing),
/// amber (needs greenlight), green + ✓ (complete).
private struct AgentMark: View {
    let session: SessionVM
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    private var color: Color {
        if session.isDone { return theme.success }
        if session.needsGreenlight { return theme.warning }
        return theme.accent
    }

    var body: some View {
        ZStack {
            // Running → a soft pulsing halo (radar-ping, kept subtle so it stays inside the capsule).
            if session.isRunning && !reduceMotion {
                Circle()
                    .stroke(theme.accent, lineWidth: 1.5)
                    .frame(width: 36, height: 36)
                    .scaleEffect(pulse ? 1.5 : 1)
                    .opacity(pulse ? 0 : 0.6)
                    .animation(.easeOut(duration: 1.6).repeatForever(autoreverses: false), value: pulse)
                    .onAppear { pulse = true }
            }
            Circle()
                .fill(color.opacity(0.14))
                .overlay(Circle().strokeBorder(color, lineWidth: 1.5))
                .frame(width: 36, height: 36)
            // Brand cursor arrowhead — white keyline under a status-colored fill.
            DirectorArrow()
                .stroke(.white, lineWidth: 2)
                .background(DirectorArrow().fill(color))
                .frame(width: 15, height: 16)
            if session.isDone {
                Circle()
                    .fill(theme.success)
                    .frame(width: 14, height: 14)
                    .overlay(Image(systemName: "checkmark").font(.system(size: 8, weight: .bold)).foregroundStyle(.white))
                    .offset(x: 14, y: 14)
            }
        }
        .frame(width: 36, height: 36)
        .help("\(session.agent): \(session.title)")
        .accessibilityLabel("\(session.agent): \(session.title)")
        .accessibilityValue(session.isDone ? "complete" : session.needsGreenlight ? "needs greenlight" : "running")
    }
}

// MARK: - Open Home

private struct ExpandButton: View {
    var action: () -> Void
    @Environment(\.theme) private var theme
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(theme.textSecondary)
                .frame(width: 34, height: 34)
                .background(Circle().fill(hovering ? theme.separator : theme.controlBg))
                .overlay(Circle().strokeBorder(theme.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Open Home")
        .accessibilityLabel("Open Home")
    }
}

// MARK: - Brand cursor arrowhead (the one custom shape — canonical design path)

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
