//
//  HomeDashboardView.swift
//  DirectorSidecar
//
//  Director's one window. Home is the unified supervision surface (the merged fleet + Intention
//  Log): live agent cards grouped Needs-you → Active, then the timestamped "Earlier today" log of
//  past intentions, with the Inspector trailing the selection. Briefs is a coming-soon tease (saved
//  reusable commands — the validated power-user/accessibility feature). Settings + Help pin to the
//  sidebar footer. Native SwiftUI throughout: NavigationSplitView, themed pill, no orphaned chrome.
//

import SwiftUI
import AppKit

struct HomeDashboardView: View {
    @Bindable var model: HomeDashboardModel
    @Environment(\.theme) private var theme

    enum NavItem: String, CaseIterable, Identifiable {
        case home = "Home"
        case logs = "Agent Logs"
        case briefs = "Briefs"
        case settings = "Settings"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .home: return "house"
            case .logs: return "list.bullet.rectangle"
            case .briefs: return "command"
            case .settings: return "gearshape"
            }
        }
    }

    /// Primary nav (Settings + Help live pinned in the sidebar footer, not this list).
    private static let primaryNav: [NavItem] = [.home, .logs, .briefs]

    @State private var nav: NavItem = .home

    private var needsYou: [SessionVM] { model.sessions.filter(\.needsGreenlight) }
    private var active: [SessionVM] { model.sessions.filter(\.isRunning) }

    var body: some View {
        NavigationSplitView {
            List(Self.primaryNav, selection: $nav) { item in
                Label(item.rawValue, systemImage: item.icon).tag(item)
            }
            .navigationSplitViewColumnWidth(220)
            .navigationTitle("Director")
            .safeAreaInset(edge: .bottom) { sidebarFooter }
        } detail: {
            detail
        }
    }

    // MARK: detail

    @ViewBuilder private var detail: some View {
        switch nav {
        case .home:
            homeColumn
                .navigationTitle("Home")
                .toolbar { ToolbarItem(placement: .navigation) { ListeningPill(level: model.readiness) } }
                .inspector(isPresented: .constant(model.selectedSessionId != nil)) {
                    InspectorView(model: model)
                        .inspectorColumnWidth(min: 280, ideal: 300, max: 360)
                }
        case .logs:
            IntentionLogView(entries: model.auditLog)
                .navigationTitle("Agent Logs")
        case .briefs:
            ComingSoonView(
                title: "Briefs", icon: "command",
                blurb: "Save an intention once, then say a word to run it.\n“Ship the PR.”  “Summarize this to #eng.”  “Draft my standup.”"
            )
            .navigationTitle("Briefs")
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
        AgentCard(session: session, selected: session.id == model.selectedSessionId)
            .onTapGesture { model.select(session.id) }
    }

    // MARK: sidebar footer (pinned Settings + Help)

    private var sidebarFooter: some View {
        VStack(spacing: 2) {
            Divider().padding(.bottom, 4)
            SidebarFooterRow(title: "Settings", icon: "gearshape", selected: nav == .settings) {
                nav = .settings
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

/// The readiness/listening status as a themed pill (was an orphaned dot+label in the toolbar).
private struct ListeningPill: View {
    let level: ReadinessLevel
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 6) {
            ReadinessDot(level: level)
            Text(BridgeStore.readinessLabel(for: level))
                .font(theme.kbd).foregroundStyle(theme.textSecondary)
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(Capsule(style: .continuous).fill(theme.cardInset))
        .overlay(Capsule(style: .continuous).strokeBorder(theme.border, lineWidth: 1))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Status")
        .accessibilityValue(level.spoken)
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
