//
//  DirectorSidecarApp.swift
//  DirectorSidecar
//
//  App scenes + composition root. ONE shared BridgeConnection (locked decision) fans out frames
//  to every model — the menu BridgeStore and the HUD HUDModel — over a single socket; commands
//  route back through it. The HUD lives in a non-activating NSPanel driven by HUDPanelController.
//  Theme is resolved per scene from the live color scheme.
//

import SwiftUI

@main
struct DirectorSidecarApp: App {
    let store: BridgeStore
    let hud: HUDModel
    let micro: MicroHUDModel
    private let connection: BridgeConnection
    private let hudController: HUDPanelController
    private let microController: MicroHUDController

    init() {
        let connection = BridgeConnection()
        let store = BridgeStore()
        let hud = HUDModel()
        let micro = MicroHUDModel()
        store.bridge = connection
        hud.connection = connection
        // Menu Start/Stop Listening brings the overlays up/down optimistically (no "amListening").
        store.onListeningChanged = { on in
            hud.setListening(on)
            micro.setListening(on)
        }

        self.connection = connection
        self.store = store
        self.hud = hud
        self.micro = micro
        self.hudController = HUDPanelController(model: hud, edge: .trailing)
        self.microController = MicroHUDController(
            model: micro, fullHUD: hud, onOpenHome: { store.send(.openHome) }
        )

        #if DEBUG
        if DevMockFleet.isEnabled {
            Task {
                await DevMockFleet.drive(
                    dispatch: { frame in store.apply(frame); hud.apply(frame); micro.apply(frame) },
                    setState: { state in store.setConnection(state); micro.setConnection(state) },
                    now: Date()
                )
            }
        } else {
            Self.stream(connection, store, hud, micro)
        }
        #else
        Self.stream(connection, store, hud, micro)
        #endif
    }

    /// Start the single socket and fan every frame/state out to all models (one shared connection).
    private static func stream(_ connection: BridgeConnection, _ store: BridgeStore, _ hud: HUDModel, _ micro: MicroHUDModel) {
        Task {
            await connection.start(
                onFrame: { frame in
                    await store.apply(frame)
                    await hud.apply(frame)
                    await micro.apply(frame)
                },
                onState: { state in
                    await store.setConnection(state)
                    await hud.setConnection(state)
                    await micro.setConnection(state)
                }
            )
        }
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
