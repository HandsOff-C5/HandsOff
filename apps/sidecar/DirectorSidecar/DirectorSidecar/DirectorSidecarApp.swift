//
//  DirectorSidecarApp.swift
//  DirectorSidecar
//
//  Two scenes (G1): the G0 readiness WindowGroup is kept as the debug/fallback scene, and a
//  MenuBarExtra(.window) is the product's persistent entry point. Both share the one BridgeStore
//  (backed by the single shared BridgeConnection). Theme is resolved per scene from the live
//  color scheme so light/dark flip correctly.
//

import SwiftUI

@main
struct DirectorSidecarApp: App {
    let store: BridgeStore

    init() {
        let store = BridgeStore()
        #if DEBUG
        if DevMockFleet.isEnabled {
            Task { await DevMockFleet.drive(store, now: Date()) }
        } else {
            store.start()
        }
        #else
        store.start()
        #endif
        self.store = store
    }

    var body: some Scene {
        // G0 debug / fallback window — kept working alongside the menu bar.
        WindowGroup {
            ThemedRoot { ContentView() }
        }

        // G1 product entry: menu-bar status item + glass dropdown.
        MenuBarExtra {
            ThemedRoot { MenuContent(store: store) }
        } label: {
            ThemedRoot { MenuBarLabel(readiness: store.menuReadiness) }
        }
        .menuBarExtraStyle(.window)
    }
}

/// Resolves the design Theme from the live color scheme and injects it into the environment,
/// so every child reads tokens via `@Environment(\.theme)` (no hard-coded hex anywhere).
struct ThemedRoot<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    @ViewBuilder let content: Content

    var body: some View {
        content.environment(\.theme, Theme.resolve(colorScheme))
    }
}
