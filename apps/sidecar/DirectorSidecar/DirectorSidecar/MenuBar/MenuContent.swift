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
        Button("Open Dashboard") { store.send(.openHome) }

        Divider()

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
                ForEach(store.sessions) { session in
                    Button(session.title) {
                        store.send(.selectSession(session.id))
                        store.send(.openHome)
                    }
                }
            }
        }

        Divider()

        Button("Pause all agents") { store.send(.pauseAll) }
            .disabled(store.runningCount == 0)

        Divider()

        Button("Preferences…") { NSApp.activate(ignoringOtherApps: true) }
        Button("Quit Director") { NSApp.terminate(nil) }

        if store.connection != .connected {
            Divider()
            Text(BridgeStore.connectionLabel(store.connection))   // disabled status line
        }
    }
}
