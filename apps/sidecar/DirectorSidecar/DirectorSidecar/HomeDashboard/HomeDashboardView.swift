//
//  HomeDashboardView.swift
//  DirectorSidecar
//
//  Home Dashboard shell — NavigationSplitView (220pt sidebar). Home = the Intention Log feed;
//  Agents = the live AgentCard fleet + Inspector; Settings (pinned bottom). Help (pinned bottom)
//  drafts a support email. The toolbar + Inspector are scoped to the Agents tab only.
//

import SwiftUI
import AppKit

struct HomeDashboardView: View {
    @Bindable var model: HomeDashboardModel
    @Environment(\.theme) private var theme

    enum NavItem: String, CaseIterable, Identifiable {
        case home = "Home"
        case agents = "Agents"
        case settings = "Settings"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .home: return "house"
            case .agents: return "square.grid.2x2"
            case .settings: return "gearshape"
            }
        }
    }

    /// The primary nav (the pinned Settings + Help live in the sidebar footer, not this list).
    private static let primaryNav: [NavItem] = [.home, .agents]

    @State private var nav: NavItem = .home

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
            HomeFeedView(entries: model.intentions)
        case .agents:
            agentsColumn
                .toolbar { agentsToolbar }
                .inspector(isPresented: .constant(model.selectedSessionId != nil)) {
                    InspectorView(model: model)
                        .inspectorColumnWidth(min: 280, ideal: 300, max: 360)
                }
        case .settings:
            DashboardSettingsView()
        }
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
        let subject = "Director Support"
        let url = "mailto:jasondijols@gmail.com?subject=\(subject.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? subject)"
        if let mailto = URL(string: url) { NSWorkspace.shared.open(mailto) }
    }

    @ViewBuilder private var agentsColumn: some View {
        switch model.loadState {
        case .error:
            ContentUnavailableView("Engine offline", systemImage: "bolt.horizontal.circle",
                                   description: Text("Reconnecting to the Director engine…"))
        case .denied:
            ContentUnavailableView("Connection blocked", systemImage: "lock.shield",
                                   description: Text("Open System Settings to allow the bridge."))
        case .empty:
            ContentUnavailableView("No active sessions", systemImage: "waveform",
                                   description: Text("Point and speak to start an agent."))
        case .connecting, .loaded:
            if model.filteredSessions.isEmpty, model.loadState == .loaded {
                ContentUnavailableView("No \(model.filter.rawValue) agents", systemImage: "line.3.horizontal.decrease.circle")
            } else {
                ScrollView {
                    LazyVStack(spacing: theme.elementGap) {
                        ForEach(model.filteredSessions) { session in
                            AgentCard(session: session, selected: session.id == model.selectedSessionId)
                                .onTapGesture { model.select(session.id) }
                        }
                    }
                    .padding(theme.windowPadding)
                }
            }
        }
    }

    @ToolbarContentBuilder private var agentsToolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            HStack(spacing: 5) {
                ReadinessDot(level: model.readiness)
                Text(BridgeStore.readinessLabel(for: model.readiness)).font(theme.kbd).foregroundStyle(theme.textSecondary)
            }
        }
        ToolbarItem(placement: .primaryAction) {
            DirectorFilterControl(filter: $model.filter, counts: model.counts)
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

/// Custom segmented filter with SF Mono per-segment counts (a Picker(.segmented) can't).
private struct DirectorFilterControl: View {
    @Binding var filter: HomeDashboardModel.Filter
    let counts: SessionCounts
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 2) {
            ForEach(HomeDashboardModel.Filter.allCases, id: \.self) { option in
                Button { filter = option } label: {
                    HStack(spacing: 4) {
                        Text(label(option)).font(theme.body)
                        if let n = count(option) {
                            Text("\(n)").font(theme.mono).foregroundStyle(theme.textTertiary)
                        }
                    }
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: theme.radiusControl, style: .continuous)
                        .fill(filter == option ? theme.controlBg : .clear))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: theme.radiusControl + 2, style: .continuous).fill(theme.cardInset))
    }

    private func label(_ option: HomeDashboardModel.Filter) -> String {
        switch option {
        case .all: return "All"
        case .running: return "Running"
        case .needsYou: return "Needs you"
        case .done: return "Done"
        }
    }

    private func count(_ option: HomeDashboardModel.Filter) -> Int? {
        switch option {
        case .all: return nil
        case .running: return counts.running
        case .needsYou: return counts.needsGreenlight
        case .done: return counts.done
        }
    }
}
