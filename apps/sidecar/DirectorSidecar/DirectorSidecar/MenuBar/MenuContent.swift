//
//  MenuContent.swift
//  DirectorSidecar
//
//  The glass dropdown body for MenuBarExtra(.window) (G1). Renders every enumerated menu state
//  from the BridgeStore: readiness header, Activate Director (disabled/active), the AGENTS section
//  + live rows / empty placeholder, Pause all (enabled iff running), Open Home, Preferences,
//  Quit, and the connection banner. Glass → opaque under Reduce Transparency.
//

import SwiftUI
import AppKit

struct MenuContent: View {
    let store: BridgeStore

    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        VStack(spacing: 0) {
            MenuActionRow(title: "Open Dashboard", trailing: "⇧⌘M") { store.send(.openHome) }

            divider

            MenuActionRow(
                title: store.isListening ? "Deactivate Director" : "Activate Director",
                trailing: "⌥⌘D", enabled: store.canListen, active: store.isListening
            ) { store.send(store.isListening ? .stopListening : .startListening) }

            if !store.canListen, store.menuReadiness == .blocked {
                Text("Microphone access needed")
                    .font(theme.kbd).foregroundStyle(theme.textTertiary)
                    .padding(.horizontal, 18).padding(.bottom, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            SectionLabel("AGENTS · \(store.runningCount) RUNNING")
                .padding(.horizontal, 18).padding(.top, 8).padding(.bottom, 3)
                .frame(maxWidth: .infinity, alignment: .leading)

            if store.sessions.isEmpty {
                EmptyAgentsRow()
            } else {
                ForEach(store.sessions) { session in
                    SessionRow(session: session) {
                        store.send(.selectSession(session.id))
                        store.send(.openHome)
                    }
                }
            }

            divider
            MenuActionRow(title: "Pause all agents",
                          enabled: store.runningCount > 0) { store.send(.pauseAll) }

            divider
            MenuActionRow(title: "Preferences…", trailing: "⌘,") {
                NSApp.activate(ignoringOtherApps: true)
            }
            MenuActionRow(title: "Quit Director", trailing: "⌘Q") {
                NSApp.terminate(nil)
            }

            if store.connection != .connected {
                ConnectionBanner(state: store.connection).padding(.top, 4)
            }
        }
        .padding(.vertical, 6)
        .frame(width: theme.menuWidth)
        .background(menuBackground)
    }

    private var divider: some View {
        Divider().overlay(theme.separator).padding(.vertical, 4)
    }

    @ViewBuilder private var menuBackground: some View {
        if reduceTransparency {
            theme.opaqueSurface
        } else {
            // `.behindWindow` samples the desktop behind the panel (true glass); the default
            // `.withinWindow` only blends in-window content, which read as a flat opaque gray.
            VisualEffectBlur(.menu, blending: .behindWindow)
        }
    }
}
