//
//  MenuContent.swift
//  DirectorSidecar
//
//  The status-item dropdown — declared as a NATIVE pull-down menu (MenuBarExtra `.menu` style), so
//  macOS itself draws the liquid-glass material, the system selection highlight, and standard menu
//  spacing. We only declare the items (Buttons / Section / Divider / disabled Text); no custom
//  chrome, no brand styling. Benchmarked against Wispr Flow + Granola, which both use the system
//  NSMenu for their status item. State is read from the BridgeStore each time the menu opens.
//

import SwiftUI
import AppKit

struct MenuContent: View {
    let store: BridgeStore

    var body: some View {
        Button("Open Director") { store.send(.openHome) }

        Divider()

        // No keyboard shortcut yet: activation is fn-hold, and the fn/globe key isn't a representable
        // SwiftUI shortcut — it returns with AppKit-level menu control in the onboarding step.
        Button(store.isListening ? "Deactivate Director" : "Activate Director") {
            store.send(store.isListening ? .stopListening : .startListening)
        }
        .disabled(!store.canListen)

        if !store.canListen, store.menuReadiness == .blocked {
            Text("Microphone access needed")   // disabled informational item
        }

        Section("Agents · \(store.runningCount) running") {
            if store.sessions.isEmpty {
                Text("No agents running")
            } else {
                // Each running agent is a submenu (the › chevron) → its per-agent actions.
                ForEach(store.sessions) { session in
                    Menu(session.title) {
                        Button("View Activity") {
                            store.send(.selectSession(session.id))
                            store.send(.openHome)
                        }
                        Button("Pause Agent") { store.send(.pauseSession(session.id)) }
                    }
                }
            }
        }

        Divider()

        Button("Pause all agents") { store.send(.pauseAll) }
            .disabled(store.runningCount == 0)

        Divider()

        Button("Settings…") { store.openSettings() }
        Button("Quit Director") { NSApp.terminate(nil) }
            .keyboardShortcut("q", modifiers: .command)

        if store.connection != .connected {
            Divider()
            Text(BridgeStore.connectionLabel(store.connection))   // disabled status line
        }
    }
}
