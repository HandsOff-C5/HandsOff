//
//  RailView.swift
//  DirectorSidecar
//
//  The Right-edge rail. Collapsed it's an icon column; on hover it widens LEFTWARD to a fixed width
//  (the right edge never moves) and the row labels fade in behind it. Each row is interactive with a
//  macOS-menu-style hover highlight: clicking the text or the icon runs the same action. Agent rows
//  are the exception — hovering the mark swaps it to a Pause button (pause that agent), while the
//  rest of the row opens the dashboard to that agent. Rows: Activated · agent marks · Open Director.
//

import SwiftUI

struct RailView: View {
    let model: RailModel
    let store: BridgeStore

    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var expanded: Bool { model.isHovering }
    private static let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
    /// A friendly, slightly slower ease for the widen/collapse so it doesn't feel snappy/jarring.
    static let ease = Animation.smooth(duration: 0.34)
    /// FIXED inner widths — the rail never measures the text, so the right edge can't jump.
    private var contentWidth: CGFloat { expanded ? 156 : 48 }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if model.isListening {
                ActivatedRow(expanded: expanded) { store.send(.stopListening) }
                divider
            }
            if !model.marks.isEmpty {
                ForEach(model.marks) { mark in
                    AgentRow(
                        mark: mark, expanded: expanded,
                        onView: { store.send(.selectSession(mark.id)); store.send(.openHome) },
                        onPause: { store.send(.pauseSession(mark.id)) }
                    )
                }
                divider
            }
            OpenRow(expanded: expanded) { store.send(.openHome) }
        }
        .frame(width: contentWidth, alignment: .leading)
        .padding(.vertical, 11)
        .padding(.horizontal, 6)
        .background {
            if reduceTransparency {
                Self.shape.fill(theme.opaqueSurface)
            } else {
                VisualEffectBlur(.hudWindow, blending: .behindWindow)
            }
        }
        .clipShape(Self.shape)
        .overlay(Self.shape.strokeBorder(theme.border, lineWidth: 1))
        .frame(maxWidth: .infinity, alignment: .trailing) // hug the screen's right edge; widen left
        .animation(Self.ease, value: model.isHovering)
        .animation(theme.standardMotion, value: model.isListening)
        .animation(theme.standardMotion, value: model.marks)
        .onHover { model.setHovering($0) }
    }

    private var divider: some View {
        Divider().overlay(theme.separator).padding(.horizontal, 2).padding(.vertical, 3)
    }
}

// MARK: - Row layout + hover highlight (the macOS-menu-style selection)

private struct RowShell<Icon: View>: View {
    let expanded: Bool
    let hovering: Bool
    let label: String
    var labelColor: Color? = nil
    @ViewBuilder var icon: () -> Icon

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 12) {
            icon().frame(width: 36, alignment: .center)
            Text(label)
                .font(theme.body)
                .foregroundStyle(labelColor ?? theme.textPrimary)
                .lineLimit(1)
                .frame(width: 96, alignment: .leading)
                .opacity(expanded ? 1 : 0)
        }
        .padding(.horizontal, 6).padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(hovering && expanded ? theme.controlBg : .clear)) // same hover token as the dashboard
        .contentShape(Rectangle())
    }
}

// MARK: - Activated / Deactivate (the listening row)

private struct ActivatedRow: View {
    let expanded: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            RowShell(expanded: expanded, hovering: hovering,
                     label: hovering ? "Deactivate" : "Activated") {
                ListeningWaveform()
            }
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Deactivate Director")
        .accessibilityLabel(expanded && hovering ? "Deactivate Director" : "Activated")
    }
}

// MARK: - Open Director

private struct OpenRow: View {
    let expanded: Bool
    let action: () -> Void
    @Environment(\.theme) private var theme
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            RowShell(expanded: expanded, hovering: hovering, label: "Open Director") {
                // Circle to echo the agent marks (the user preferred this over a bare glyph).
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(theme.textSecondary)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(theme.controlBg))
                    .overlay(Circle().strokeBorder(theme.border, lineWidth: 1))
            }
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Open Director")
        .accessibilityLabel("Open Director")
    }
}

// MARK: - Agent row (row → View Activity; icon hover → Pause)

private struct AgentRow: View {
    let mark: SessionVM
    let expanded: Bool
    let onView: () -> Void
    let onPause: () -> Void

    @Environment(\.theme) private var theme
    @State private var rowHover = false
    @State private var iconHover = false

    private var canPause: Bool { mark.isRunning }

    var body: some View {
        HStack(spacing: 12) {
            // The mark — hover swaps it to a Pause button for running agents.
            Button(action: { canPause ? onPause() : onView() }) {
                ZStack {
                    DirectorMark(status: mark.status, size: 36)
                        .opacity(iconHover && canPause ? 0 : 1)
                    if canPause {
                        Image(systemName: "pause.fill")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(theme.goldInk)
                            .frame(width: 36, height: 36)
                            .background(Circle().fill(theme.accent))
                            .opacity(iconHover ? 1 : 0)
                    }
                }
                .frame(width: 36, height: 36)
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .onHover { iconHover = $0 }
            .help(iconHover && canPause ? "Pause agent" : "\(mark.agent): \(mark.title)")

            // The rest of the row → View Activity.
            Button(action: onView) {
                HStack(spacing: 0) {
                    Text(mark.agent)
                        .font(theme.body).foregroundStyle(theme.textPrimary)
                        .lineLimit(1).frame(width: 96, alignment: .leading)
                    Spacer(minLength: 0)
                }
                .opacity(expanded ? 1 : 0)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 6).padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(rowHover && expanded ? theme.controlBg : .clear)) // same hover token as the dashboard
        .onHover { rowHover = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(mark.agent): \(mark.title)")
    }
}
