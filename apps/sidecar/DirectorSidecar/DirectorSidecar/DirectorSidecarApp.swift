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
import AppKit

/// The overlay/HUD panels order-front *without* activating (by design), so nothing brings the app
/// forward at launch and the Dashboard window never becomes key — leaving its content unclickable
/// and app keyboard shortcuts (⌥⌘D) dead. Explicitly activate on launch so the window is interactive.
final class DirectorAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        makeDashboardKey()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.makeDashboardKey() }
    }

    // The overlay/HUD are non-key floating panels, so nothing claims key on its own — force the
    // Dashboard to become key whenever the app activates, or its content stays unclickable.
    func applicationDidBecomeActive(_ notification: Notification) {
        makeDashboardKey()
    }

    private func makeDashboardKey() {
        let dashboard = NSApp.windows.first { $0.title == "Director" }
            ?? NSApp.windows.first { $0.canBecomeKey && !($0 is NSPanel) && !$0.className.contains("StatusBar") }
        dashboard?.makeKeyAndOrderFront(nil)
    }
}

@main
struct DirectorSidecarApp: App {
    @NSApplicationDelegateAdaptor(DirectorAppDelegate.self) private var appDelegate
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

        // One fan-out of every decoded frame to every model.
        let dispatch: (BridgeFrame) -> Void = { frame in
            store.apply(frame); hud.apply(frame); micro.apply(frame)
            overlay.apply(frame); gaze.apply(frame); home.apply(frame)
        }

        // Listening toggle (the "fn" of this build): brings the three active overlays up/down. In
        // mock mode it (re)runs the activation loop on each ON; OFF cancels it and clears them.
        var activation: Task<Void, Never>?
        store.onListeningChanged = { on in
            hud.setListening(on)
            micro.setListening(on)
            overlay.setActive(on)  // Director cursor hugs the system cursor while active
            gaze.setActive(on)     // eye-gaze brackets shown while active
            #if DEBUG
            activation?.cancel()
            if on, DevMockFleet.isEnabled {
                activation = Task { await DevMockFleet.activationLoop(dispatch: dispatch, now: Date()) }
            }
            #endif
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
            // Populate the dashboard + inspector at launch; overlays stay DOWN until you toggle
            // Listening (⌥⌘D, or the menu) — so the menu + dashboard are never obstructed.
            Task {
                await DevMockFleet.populate(
                    dispatch: dispatch,
                    setState: { state in store.setConnection(state); micro.setConnection(state); overlay.setConnection(state); gaze.setConnection(state); home.setConnection(state) },
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

    /// Toggle the listening overlays from anywhere in the app (⌥⌘D or the Director menu).
    private func toggleListening() {
        store.send(store.isListening ? .stopListening : .startListening)
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
        .commands {
            CommandMenu("Director") {
                Button("Toggle Listening") { toggleListening() }
                    .keyboardShortcut("d", modifiers: [.command, .option])
            }
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
