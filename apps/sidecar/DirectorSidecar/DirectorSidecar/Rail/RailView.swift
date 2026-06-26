//
//  RailView.swift
//  DirectorSidecar
//
//  The Right-edge rail capsule (design: right-edge-rail-spec.md). Super-native: NSVisualEffectView
//  `.hudWindow` glass behind a SwiftUI `Capsule`, gold the only brand color. Collapsed it's a column
//  of icons (the shared DirectorMark + listening waveform); on hover it widens leftward to reveal
//  each row's text label. Top→bottom: listening pip · agent marks · Open-Director.
//

import SwiftUI

struct RailView: View {
    let model: RailModel
    var onExpand: () -> Void

    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var expanded: Bool { model.isHovering }

    /// Continuous rounded-rect (not a full capsule) so the expanded panel reads as a clean card.
    private static let shape = RoundedRectangle(cornerRadius: 24, style: .continuous)

    var body: some View {
        VStack(alignment: .leading, spacing: theme.elementGap) {
            if model.isListening {
                RailRow(label: "Listening", expanded: expanded) {
                    ListeningWaveform()
                }
                divider
            }
            if !model.marks.isEmpty {
                ForEach(model.marks) { mark in
                    RailRow(label: mark.agent, expanded: expanded) {
                        DirectorMark(status: mark.status, size: 36)
                    }
                    .help("\(mark.agent): \(mark.title)")
                    .accessibilityLabel("\(mark.agent): \(mark.title)")
                }
                divider
            }
            RailRow(label: "Open Director", expanded: expanded) {
                ExpandButton(action: onExpand)
            }
        }
        .padding(.vertical, theme.elementGap)
        .padding(.horizontal, theme.elementGap)
        .background {
            if reduceTransparency {
                Self.shape.fill(theme.opaqueSurface)
            } else {
                VisualEffectBlur(.hudWindow, blending: .behindWindow).clipShape(Self.shape)
            }
        }
        .overlay(Self.shape.strokeBorder(theme.border, lineWidth: 1))
        .fixedSize()
        .frame(maxWidth: .infinity, alignment: .trailing) // hug the right edge within the resized panel
        .animation(theme.quickMotion, value: model.isHovering)
        .animation(theme.standardMotion, value: model.isListening)
        .animation(theme.standardMotion, value: model.marks)
        .onHover { model.setHovering($0) }
    }

    private var divider: some View {
        Divider().overlay(theme.separator)
    }
}

// MARK: - A rail row: an icon with a hover-revealed text label to its left

private struct RailRow<Icon: View>: View {
    let label: String
    let expanded: Bool
    @ViewBuilder let icon: Icon

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 12) {
            icon.frame(width: 36, alignment: .center)
            if expanded {
                Text(label)
                    .font(theme.body)
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)
                    .frame(width: 100, alignment: .leading) // fixed column → labels align, content fits snug
                    .transition(.opacity)
            }
        }
    }
}

// MARK: - Open Director

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
        .help("Open Director")
        .accessibilityLabel("Open Director")
    }
}
