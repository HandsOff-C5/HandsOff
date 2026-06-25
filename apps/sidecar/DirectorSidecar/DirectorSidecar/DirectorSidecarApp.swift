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
    let overlay: OverlayModel
    let gaze: GazeBracketModel
    let home: HomeDashboardModel
    private let connection: BridgeConnection
    private let hudController: HUDPanelController
    private let microController: MicroHUDController
    private let overlayController: OverlayController

    init() {
        let connection = BridgeConnection()
        let store = BridgeStore()
        let hud = HUDModel()
        let micro = MicroHUDModel()
        let overlay = OverlayModel()
        let gaze = GazeBracketModel()
        let home = HomeDashboardModel()
        store.bridge = connection
        home.bridge = connection
        hud.connection = connection
        // Menu Start/Stop Listening brings the three active overlays up/down (no "amListening").
        store.onListeningChanged = { on in
            hud.setListening(on)
            micro.setListening(on)
            overlay.setActive(on)  // Director cursor hugs the system cursor while active
            gaze.setActive(on)     // eye-gaze brackets are always shown while active
        }

        self.connection = connection
        self.store = store
        self.hud = hud
        self.micro = micro
        self.overlay = overlay
        self.gaze = gaze
        self.home = home
        self.hudController = HUDPanelController(model: hud, edge: .trailing)
        self.microController = MicroHUDController(
            model: micro, fullHUD: hud, onOpenHome: { store.send(.openHome) }
        )
        self.overlayController = OverlayController(model: overlay, gaze: gaze)

        #if DEBUG
        if DevMockFleet.isEnabled {
            Task {
                await DevMockFleet.drive(
                    dispatch: { frame in store.apply(frame); hud.apply(frame); micro.apply(frame); overlay.apply(frame); gaze.apply(frame); home.apply(frame) },
                    setState: { state in store.setConnection(state); micro.setConnection(state); overlay.setConnection(state); gaze.setConnection(state); home.setConnection(state) },
                    activate: { on in hud.setListening(on); micro.setListening(on); overlay.setActive(on); gaze.setActive(on) },
                    select: { id in home.select(id) },
                    now: Date()
                )
            }
        } else {
            Self.stream(connection, store, hud, micro, overlay, gaze, home)
        }
        #else
        Self.stream(connection, store, hud, micro, overlay, gaze, home)
        #endif
    }

    /// Start the single socket and fan every frame/state out to all models (one shared connection).
    private static func stream(_ connection: BridgeConnection, _ store: BridgeStore, _ hud: HUDModel, _ micro: MicroHUDModel, _ overlay: OverlayModel, _ gaze: GazeBracketModel, _ home: HomeDashboardModel) {
        Task {
            await connection.start(
                onFrame: { frame in
                    await store.apply(frame)
                    await hud.apply(frame)
                    await micro.apply(frame)
                    await overlay.apply(frame)
                    await gaze.apply(frame)
                    await home.apply(frame)
                },
                onState: { state in
                    await store.setConnection(state)
                    await hud.setConnection(state)
                    await micro.setConnection(state)
                    await overlay.setConnection(state)
                    await gaze.setConnection(state)
                    await home.setConnection(state)
                }
            )
        }
    }

    var body: some Scene {
        // G4 Home Dashboard — the product window (native SwiftUI, Option B).
        WindowGroup("Director", id: "home") {
            ThemedRoot { HomeDashboardView(model: home) }
        }

        // G0 readiness — kept as a debug/fallback window.
        Window("Engine Readiness", id: "readiness") {
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
