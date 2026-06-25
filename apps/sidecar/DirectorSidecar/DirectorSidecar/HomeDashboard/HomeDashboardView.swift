//
//  HomeDashboardView.swift
//  DirectorSidecar
//
//  G4a Home Dashboard shell — NavigationSplitView (240pt sidebar) + the AgentCard fleet from the
//  sessions topic + a toolbar with the Listening pill and a filter segmented control with mono
//  counts. Sidebar sub-views are "Coming soon" (deferred). The Inspector arrives in G4b.
//

import SwiftUI

struct HomeDashboardView: View {
    @Bindable var model: HomeDashboardModel
    @Environment(\.theme) private var theme

    enum NavItem: String, CaseIterable, Identifiable {
        case agents = "Agents"
        case logs = "Agent Logs"
        case flow = "Intention Flow"
        case resources = "Resources"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .agents: return "square.grid.2x2"
            case .logs: return "list.bullet.rectangle"
            case .flow: return "point.topleft.down.to.point.bottomright.curvepath"
            case .resources: return "cube.box"
            }
        }
    }

    @State private var nav: NavItem = .agents

    var body: some View {
        NavigationSplitView {
            List(NavItem.allCases, selection: $nav) { item in
                Label(item.rawValue, systemImage: item.icon).tag(item)
            }
            .navigationSplitViewColumnWidth(240)
            .navigationTitle("Director")
        } detail: {
            detail
                .toolbar { toolbar }
                .inspector(isPresented: .constant(model.selectedSessionId != nil)) {
                    InspectorView(model: model)
                        .inspectorColumnWidth(min: 280, ideal: 300, max: 360)
                }
        }
    }

    @ViewBuilder private var detail: some View {
        switch nav {
        case .agents:
            agentsColumn
        default:
            ContentUnavailableView("Coming soon", systemImage: nav.icon,
                                   description: Text("\(nav.rawValue) lands after the demo."))
        }
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

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
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
