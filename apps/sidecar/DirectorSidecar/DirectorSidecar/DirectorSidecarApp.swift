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

/// Owns the overlay/HUD/micro controllers. Built empty up front, but the controllers — whose
/// always-on-top panels (`orderFrontRegardless`) + global `.mouseMoved` monitors corrupt app-wide
/// event delivery if created during `App.init()` — are only constructed when `start()` is invoked
/// from `applicationDidFinishLaunching`, i.e. after AppKit has finished wiring the app's event routing.
@MainActor final class SurfaceHost {
    /// The ambient "WORKING" edge pill (G3 micro-HUD) is parked — product hasn't committed to showing
    /// it in the end-user experience. Flip to `true` to bring it (and its idle edge-reveal) back.
    static let showsMicroHUD = false

    private var hud: HUDPanelController?
    private var micro: MicroHUDController?
    private var overlay: OverlayController?
    private var fnMonitor: Any?
    private var fnHeld = false

    private var railController: RailController?

    func start(hud hudModel: HUDModel, micro microModel: MicroHUDModel,
               overlay overlayModel: OverlayModel, gaze: GazeBracketModel,
               rail railModel: RailModel,
               onOpenHome: @escaping () -> Void) {
        guard hud == nil else { return }   // once only
        hud = HUDPanelController(model: hudModel, edge: .trailing)
        if Self.showsMicroHUD {
            micro = MicroHUDController(model: microModel, fullHUD: hudModel, onOpenHome: onOpenHome)
        }
        overlay = OverlayController(model: overlayModel, gaze: gaze)
        // The Right-edge rail — the always-on ambient edge surface (replaces the parked micro-HUD).
        railController = RailController(model: railModel, edge: .trailing, onOpenHome: onOpenHome)
    }

    /// Mock fn-key activation (the "fn" of this build): hold the fn/🌐 key while Director is frontmost
    /// → onHold(true); release → onHold(false). Local monitor, so no Accessibility prompt — works when
    /// Director is the active app. (Holding fn while pointing at *other* apps needs a global monitor +
    /// Accessibility; that's the next step. macOS fn behavior should be set to "Do Nothing" to avoid
    /// the system intercepting it.)
    func installFnHold(_ onHold: @escaping (Bool) -> Void) {
        guard fnMonitor == nil else { return }
        fnMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            let held = event.modifierFlags.contains(.function)
            MainActor.assumeIsolated {
                guard let self, held != self.fnHeld else { return }
                self.fnHeld = held
                onHold(held)
            }
            return event
        }
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
    let rail: RailModel
    private let connection: BridgeConnection
    private let surfaces: SurfaceHost

    init() {
        let connection = BridgeConnection()
        let store = BridgeStore()
        let hud = HUDModel()
        let micro = MicroHUDModel()
        let overlay = OverlayModel()
        let gaze = GazeBracketModel()
        let home = HomeDashboardModel()
        let rail = RailModel()
        store.bridge = connection
        home.bridge = connection
        hud.connection = connection

        // One fan-out of every decoded frame to every model.
        let dispatch: (BridgeFrame) -> Void = { frame in
            store.apply(frame); hud.apply(frame); micro.apply(frame)
            overlay.apply(frame); gaze.apply(frame); home.apply(frame); rail.apply(frame)
        }

        // Listening toggle (the "fn" of this build): brings the three active overlays up/down. In
        // mock mode it (re)runs the activation loop on each ON; OFF cancels it and clears them.
        var activation: Task<Void, Never>?
        store.onListeningChanged = { on in
            hud.setListening(on)
            micro.setListening(on)
            overlay.setActive(on)  // the one Director cursor hugs the system cursor while active
            // Eye-gaze brackets: seed a deterministic centered region so they appear on activation,
            // before real gaze CV drives them (point/size morphing lands with the engine publisher).
            let screen = NSScreen.main?.frame.size ?? CGSize(width: 1440, height: 900)
            gaze.setActive(on, seed: on ? GazeBracketModel.centeredRegion(in: screen) : nil)
            rail.setListening(on)  // the rail's LIVE pip lights while active
            #if DEBUG
            // The scripted intention journey (transcript → intent → traveling cursors → full HUD) is
            // parked behind `runsScriptedActivation`. Activation shows only the three ambient overlays
            // unless it's flipped on (the later "populate the flow" step).
            activation?.cancel()
            if DevMockFleet.isEnabled, DevMockFleet.runsScriptedActivation {
                activation = on ? Task { await DevMockFleet.activationLoop(dispatch: dispatch, now: Date()) } : nil
                if !on { dispatch(.cursor(pointers: [])) } // clear the agent cursors the loop drew
            }
            #endif
        }

        // `store.onOpenHome` (rail ⤢ + menu "Open Home") is wired to SwiftUI's openWindow in the
        // dashboard scene (HomeOpenWiring) so it re-creates the window even after the red-X close.
        self.connection = connection
        self.store = store
        self.hud = hud
        self.micro = micro
        self.overlay = overlay
        self.gaze = gaze
        self.home = home
        self.rail = rail

        // The overlay/HUD/micro controllers MUST NOT be created during App.init() — building their
        // always-on-top panels + global mouse monitors before AppKit finishes wiring event routing
        // silently kills input to the WHOLE app (Dashboard AND menu bar go dead). Defer to launch.
        let surfaces = SurfaceHost()
        self.surfaces = surfaces
        NotificationCenter.default.addObserver(
            forName: NSApplication.didFinishLaunchingNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                surfaces.start(hud: hud, micro: micro, overlay: overlay, gaze: gaze, rail: rail,
                               onOpenHome: { store.send(.openHome) })
                // fn press-and-hold drives the mock activation (hold → overlays up, release → down).
                surfaces.installFnHold { held in store.send(held ? .startListening : .stopListening) }
            }
        }

        #if DEBUG
        if DevMockFleet.isEnabled {
            // Populate the dashboard + inspector at launch; overlays stay DOWN until you toggle
            // Listening (⌥⌘D, or the menu) — so the menu + dashboard are never obstructed.
            Task {
                await DevMockFleet.populate(
                    dispatch: dispatch,
                    setState: { state in store.setConnection(state); micro.setConnection(state); overlay.setConnection(state); gaze.setConnection(state); home.setConnection(state); rail.setConnection(state) },
                    select: { id in home.select(id) },
                    now: Date()
                )
            }
        } else {
            Self.stream(connection, store, hud, micro, overlay, gaze, home, rail)
        }
        #else
        Self.stream(connection, store, hud, micro, overlay, gaze, home, rail)
        #endif
    }

    /// Toggle the listening overlays from anywhere in the app (⌥⌘D or the Director menu).
    private func toggleListening() {
        store.send(store.isListening ? .stopListening : .startListening)
    }

    /// Start the single socket and fan every frame/state out to all models (one shared connection).
    private static func stream(_ connection: BridgeConnection, _ store: BridgeStore, _ hud: HUDModel, _ micro: MicroHUDModel, _ overlay: OverlayModel, _ gaze: GazeBracketModel, _ home: HomeDashboardModel, _ rail: RailModel) {
        Task {
            await connection.start(
                onFrame: { frame in
                    await store.apply(frame)
                    await hud.apply(frame)
                    await micro.apply(frame)
                    await overlay.apply(frame)
                    await gaze.apply(frame)
                    await home.apply(frame)
                    await rail.apply(frame)
                },
                onState: { state in
                    await store.setConnection(state)
                    await hud.setConnection(state)
                    await micro.setConnection(state)
                    await overlay.setConnection(state)
                    await gaze.setConnection(state)
                    await home.setConnection(state)
                    await rail.setConnection(state)
                }
            )
        }
    }

    var body: some Scene {
        // G4 Home Dashboard — the product window. Single-instance `Window` (not `WindowGroup`) so the
        // red-X close + "Open Home" re-open cleanly via openWindow(id:) and never duplicate.
        Window("Director", id: "home") {
            ThemedRoot { HomeDashboardView(model: home) }
                .modifier(HomeOpenWiring(store: store, rail: rail))
        }
        .commands {
            CommandMenu("Director") {
                Button("Activate Director") { toggleListening() }
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

/// Wires `store.onOpenHome` (rail ⤢ + menu "Open Home") to SwiftUI's `openWindow`, captured from an
/// in-scene view so it re-creates the single-instance Home window even after the red-X destroys it.
private struct HomeOpenWiring: ViewModifier {
    let store: BridgeStore
    let rail: RailModel
    @Environment(\.openWindow) private var openWindow
    func body(content: Content) -> some View {
        content
            .onAppear {
                store.onOpenHome = {
                    MainActor.assumeIsolated {
                        openWindow(id: "home")
                        NSApp.activate()
                    }
                }
                // Home is showing → its minimized echo (the rail) hides.
                rail.setHomeOpen(true)
            }
            .onDisappear {
                // Home closed (red-X) → the rail returns as the ambient edge summary.
                rail.setHomeOpen(false)
            }
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
