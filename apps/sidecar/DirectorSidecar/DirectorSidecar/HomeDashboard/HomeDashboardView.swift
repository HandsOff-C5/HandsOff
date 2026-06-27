//
//  HomeDashboardView.swift
//  DirectorSidecar
//
//  Director's one window. Home is the unified supervision surface (the merged fleet + Intention
//  Log): live agent cards grouped Needs-you → Active, then the timestamped "Earlier today" log,
//  with the Inspector trailing the selection. Briefs is a coming-soon tease. Settings + Help pin to
//  the sidebar footer. The toolbar's primary control is the Activate/Deactivate Director button
//  (same copy + action as the menu). The sidebar is fixed — no collapse toggle.
//

import SwiftUI
import AppKit

struct HomeDashboardView: View {
    @Bindable var model: HomeDashboardModel
    let store: BridgeStore
    @Environment(\.theme) private var theme

    /// Primary nav (Settings + Help live pinned in the sidebar footer, not this list).
    private static let primaryNav: [HomeDashboardModel.Tab] = [.home, .briefs]

    private var needsYou: [SessionVM] { model.sessions.filter(\.needsGreenlight) }
    private var active: [SessionVM] { model.sessions.filter(\.isRunning) }

    var body: some View {
        NavigationSplitView {
            List(Self.primaryNav, selection: $model.tab) { item in
                Label(item.rawValue, systemImage: item.icon).tag(item)
            }
            .navigationSplitViewColumnWidth(220)
            .navigationTitle("Director")
            .safeAreaInset(edge: .bottom) { sidebarFooter }
        } detail: {
            detail
        }
        .toolbar(removing: .sidebarToggle) // the left column is fixed; no collapse control
    }

    // MARK: detail

    @ViewBuilder private var detail: some View {
        tabContent
            .navigationTitle(model.tab.rawValue) // the active tab's name on the left
            // Persistent across tabs, on the right: the Activate/Deactivate control (system-level),
            // with the listening waveform appearing to its left while active. Each is its OWN toolbar
            // item. On macOS 26 the window toolbar wraps custom content in a shared glass capsule,
            // which double-stacks behind our gold pill — `.sharedBackgroundVisibility(.hidden)` drops
            // it so the gold capsule is the single, intentional container and the waveform floats
            // bare. Pre-26 toolbars don't add that glass, so the plain items are already correct.
            .toolbar {
                if #available(macOS 26.0, *) {
                    if store.isListening {
                        ToolbarItem(placement: .primaryAction) {
                            ListeningWaveform(maxHeight: 13, minHeight: 4)
                        }
                        .sharedBackgroundVisibility(.hidden)
                    }
                    ToolbarItem(placement: .primaryAction) {
                        ActivateButton(store: store)
                    }
                    .sharedBackgroundVisibility(.hidden)
                } else {
                    if store.isListening {
                        ToolbarItem(placement: .primaryAction) {
                            ListeningWaveform(maxHeight: 13, minHeight: 4)
                        }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        ActivateButton(store: store)
                    }
                }
            }
    }

    @ViewBuilder private var tabContent: some View {
        switch model.tab {
        case .home:
            homeColumn
                .inspector(isPresented: .constant(model.selectedSessionId != nil)) {
                    InspectorView(model: model)
                        .inspectorColumnWidth(min: 280, ideal: 300, max: 360)
                }
        case .briefs:
            ComingSoonView(
                title: "Briefs", icon: "command",
                blurb: "Save an intention once, then say a word to run it.\n“Ship the PR.”  “Summarize this to #eng.”  “Draft my standup.”"
            )
        case .settings:
            DashboardSettingsView()
        }
    }

    // MARK: Home — the unified supervision surface

    @ViewBuilder private var homeColumn: some View {
        switch model.loadState {
        case .error:
            ContentUnavailableView("Engine offline", systemImage: "bolt.horizontal.circle",
                                   description: Text("Reconnecting to the Director engine…"))
        case .denied:
            ContentUnavailableView("Connection blocked", systemImage: "lock.shield",
                                   description: Text("Open System Settings to allow the bridge."))
        default:
            if model.sessions.isEmpty, model.intentions.isEmpty {
                ContentUnavailableView("Nothing running", systemImage: "waveform",
                                       description: Text("Activate Director and speak to start an agent."))
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: theme.elementGap) {
                        if !needsYou.isEmpty {
                            SectionHeader(title: "Needs you", count: needsYou.count)
                            ForEach(needsYou) { card($0) }
                        }
                        if !active.isEmpty {
                            SectionHeader(title: "Active", count: active.count)
                            ForEach(active) { card($0) }
                        }
                        if !model.intentions.isEmpty {
                            SectionHeader(title: "Earlier today", count: nil)
                                .padding(.top, needsYou.isEmpty && active.isEmpty ? 0 : 6)
                            VStack(spacing: 0) {
                                ForEach(Array(model.intentions.enumerated()), id: \.element.id) { index, entry in
                                    IntentionLogRow(entry: entry)
                                    if index < model.intentions.count - 1 { Divider() }
                                }
                            }
                        }
                    }
                    .padding(theme.windowPadding)
                }
            }
        }
    }

    private func card(_ session: SessionVM) -> some View {
        AgentCard(session: session, selected: session.id == model.selectedSessionId,
                  paused: store.isPaused(session.id),
                  onTogglePause: { store.togglePaused(session.id) })
            .onTapGesture { model.select(session.id) }
    }

    // MARK: sidebar footer (pinned Settings + Help)

    private var sidebarFooter: some View {
        VStack(spacing: 2) {
            Divider().padding(.bottom, 4)
            SidebarFooterRow(title: "Settings", icon: "gearshape", selected: model.tab == .settings) {
                model.tab = .settings
            }
            SidebarFooterRow(title: "Help", icon: "questionmark.circle", selected: false) {
                openSupportEmail()
            }
        }
        .padding(8)
    }

    private func openSupportEmail() {
        let subject = "Director Support".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "Director%20Support"
        if let mailto = URL(string: "mailto:jasondijols@gmail.com?subject=\(subject)") {
            NSWorkspace.shared.open(mailto)
        }
    }
}

// MARK: - Components

/// The toolbar's primary control — toggles listening with the same copy + action as the menu's
/// "Activate/Deactivate Director". On-brand gold (dark ink on gold, never white-on-gold).
private struct ActivateButton: View {
    let store: BridgeStore
    @Environment(\.theme) private var theme

    private var active: Bool { store.isListening }
    private var enabled: Bool { store.canListen }

    var body: some View {
        Button {
            store.send(active ? .stopListening : .startListening)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: active ? "stop.fill" : "viewfinder")
                    .font(.system(size: 11, weight: .semibold))
                Text(active ? "Deactivate Director" : "Activate Director")
                    .font(theme.body.weight(.medium))
            }
            .foregroundStyle(active ? theme.goldInk : theme.accentOnSurface)
            .padding(.horizontal, 12).padding(.vertical, 5)
            .background(Capsule(style: .continuous).fill(active ? theme.accent : theme.accentWash))
            .overlay(Capsule(style: .continuous).strokeBorder(theme.accent.opacity(active ? 0 : 0.35), lineWidth: 1))
            .opacity(enabled ? 1 : 0.45)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(active ? "Deactivate Director" : "Activate Director")
    }
}

/// An uppercase section header for the Home stacks, with an optional mono count.
private struct SectionHeader: View {
    let title: String
    var count: Int?
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 6) {
            Text(title).font(theme.sectionLabel).textCase(.uppercase).tracking(0.6)
            if let count { Text("\(count)").font(theme.mono) }
        }
        .foregroundStyle(theme.textTertiary)
        .padding(.bottom, 2)
    }
}

/// A coming-soon tab tease — native empty-state framing for a feature we want to signal.
private struct ComingSoonView: View {
    let title: String
    let icon: String
    let blurb: String
    @Environment(\.theme) private var theme

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: icon)
        } description: {
            Text(blurb)
        } actions: {
            Text("Coming soon")
                .font(theme.kbd).foregroundStyle(theme.accentOnSurface)
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(Capsule().fill(theme.accentWash))
        }
    }
}

/// A pinned sidebar-footer row (Settings / Help) styled to match the native sidebar List rows,
/// with a selection highlight that mirrors List's accent selection.
private struct SidebarFooterRow: View {
    let title: String
    let icon: String
    let selected: Bool
    let action: () -> Void

    @Environment(\.theme) private var theme
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(theme.body)
                .foregroundStyle(selected ? .white : theme.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: theme.radiusControl, style: .continuous)
                    .fill(selected ? Color.accentColor : (hovering ? theme.controlBg : .clear)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}
