//
//  DirectorSidecarApp.swift
//  DirectorSidecar
//
//  App scenes + composition root. ADR 0005 Track D ("bridge or no-bridge" → no-bridge): the ported
//  `VoiceCuaLoop` runs IN-PROCESS behind a `LoopEngine`, which fans every loop-derived frame out to
//  every model (menu BridgeStore, HUD, dashboard) and is the command sink the models send back
//  through — no loopback socket, no bridge topic expansion. The HUD lives in a non-activating
//  NSPanel driven by HUDPanelController. Theme is resolved per scene from the live color scheme.
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

    func start(hud hudModel: HUDModel, micro microModel: MicroHUDModel,
               overlay overlayModel: OverlayModel, gaze: GazeBracketModel,
               onOpenHome: @escaping () -> Void) {
        guard hud == nil else { return }   // once only
        hud = HUDPanelController(model: hudModel, edge: .trailing)
        if Self.showsMicroHUD {
            micro = MicroHUDController(model: microModel, fullHUD: hudModel, onOpenHome: onOpenHome)
        }
        overlay = OverlayController(model: overlayModel, gaze: gaze)
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
    /// ADR 0005 Track D: the in-process engine (the ported `VoiceCuaLoop`) that replaces the
    /// loopback socket as the app's engine of record. Held for the app's whole run.
    private let engine: LoopEngine
    private let surfaces: SurfaceHost
    /// Track F: the ported engine services (CUA / speech / head pointer) and the coordinator that
    /// binds their start/stop/teardown to the app lifecycle. Held for the app's whole run.
    private let services: DirectorServices
    private let coordinator: ServiceCoordinator

    init() {
        let store = BridgeStore()
        let hud = HUDModel()
        let micro = MicroHUDModel()
        let overlay = OverlayModel()
        let gaze = GazeBracketModel()
        let home = HomeDashboardModel()

        // One fan-out of every frame to every model.
        let dispatch: (BridgeFrame) -> Void = { frame in
            store.apply(frame); hud.apply(frame); micro.apply(frame)
            overlay.apply(frame); gaze.apply(frame); home.apply(frame)
        }

        // Track F: own the ported engine services and bind them to the lifecycle. Head-pointer
        // `.point` events ride the SAME fan-out the loop uses (`cursorPosition` topic), so the
        // user's head drives the Director `.user` cursor in a non-mock run.
        let services = DirectorServices()

        // Head/face tracking → intent. The latest head point lands in this shared snapshot (written
        // by the coordinator's head consumer below) and the loop's `HeadPointingIntake` reads it at
        // goal start — folding the head cursor + the windows it points at into the resolver input so a
        // look reaches the intent, not just the overlay cursor.
        let headSnapshot = HeadPointSnapshot()

        // ADR 0005 Track D — no bridge: run the ported supervision loop IN-PROCESS and make it the
        // app's engine. The loop drives the SAME frames the socket used to deliver (engine.onFrame →
        // dispatch) and the UI's commands route to the loop (the models' command sink IS the engine).
        let loop = VoiceCuaLoop(
            driver: services.cua,
            resolve: IntentWorkerConfig.resolver(),
            intake: HeadPointingIntake(snapshot: headSnapshot, driver: services.cua)
        )
        let engine = LoopEngine(loop: loop)
        engine.onFrame = { frame in dispatch(frame) }
        engine.onState = { state in
            store.setConnection(state); hud.setConnection(state); micro.setConnection(state)
            overlay.setConnection(state); gaze.setConnection(state); home.setConnection(state)
        }
        store.bridge = engine
        home.bridge = engine
        hud.connection = engine

        // The loop's transcript trigger: live STT `.final` events start a goal; partial/final also
        // surface as HUD transcript frames. (Track F bound the mic lifecycle; this is its consumer.)
        let coordinator = ServiceCoordinator(
            services: services,
            onHeadPointer: { pointer in dispatch(.cursor(pointers: [pointer])) },
            onHeadPoint: { point in headSnapshot.record(point) },
            onSpeech: { event in engine.ingestSpeech(event) }
        )

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
            if DevMockFleet.isEnabled {
                // Mock owns the cursors; the real camera/mic stay OFF so dev demos never prompt for
                // permissions or fight the mock fleet's drawn cursors.
                if on {
                    activation = Task { await DevMockFleet.activationLoop(dispatch: dispatch, now: Date()) }
                } else {
                    dispatch(.cursor(pointers: [])) // mock: clear the agent cursors the loop drew
                }
            } else {
                if on { engine.refreshReadiness() } // re-probe TCC the moment mic/speech matter
                coordinator.setSensing(on) // real head pointer + mic drive the Director cursor
            }
            #else
            if on { engine.refreshReadiness() } // re-probe TCC the moment mic/speech matter
            coordinator.setSensing(on) // real head pointer + mic drive the Director cursor
            #endif
        }

        self.engine = engine
        self.store = store
        self.hud = hud
        self.micro = micro
        self.overlay = overlay
        self.gaze = gaze
        self.home = home
        self.services = services
        self.coordinator = coordinator

        // The overlay/HUD/micro controllers MUST NOT be created during App.init() — building their
        // always-on-top panels + global mouse monitors before AppKit finishes wiring event routing
        // silently kills input to the WHOLE app (Dashboard AND menu bar go dead). Defer to launch.
        let surfaces = SurfaceHost()
        self.surfaces = surfaces
        NotificationCenter.default.addObserver(
            forName: NSApplication.didFinishLaunchingNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                surfaces.start(hud: hud, micro: micro, overlay: overlay, gaze: gaze,
                               onOpenHome: { store.send(.openHome) })
                // fn press-and-hold drives the mock activation (hold → overlays up, release → down).
                surfaces.installFnHold { held in store.send(held ? .startListening : .stopListening) }
                // Track F: begin consuming the head-pointer feed for the app's life (camera stays
                // off until Listening turns sensing on). Deferred to launch alongside the surfaces.
                coordinator.start()
            }
        }

        // Track F: release the camera/mic and finish the head stream on app quit — no leaked
        // AVCaptureSession / AVAudioEngine outliving the process.
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { coordinator.teardown() }
        }

        #if DEBUG
        if DevMockFleet.isEnabled {
            // Populate the dashboard + inspector at launch; overlays stay DOWN until you toggle
            // Listening (⌥⌘D, or the menu) — so the menu + dashboard are never obstructed. The
            // engine stays idle in mock mode (the mock fleet owns the frames); commands still
            // resolve to the engine's loop (a no-op while no goal is running).
            Task {
                await DevMockFleet.populate(
                    dispatch: dispatch,
                    setState: { state in store.setConnection(state); micro.setConnection(state); overlay.setConnection(state); gaze.setConnection(state); home.setConnection(state) },
                    select: { id in home.select(id) },
                    now: Date()
                )
            }
        } else {
            engine.start()
        }
        #else
        engine.start()
        #endif
    }

    /// Toggle the listening overlays from anywhere in the app (⌥⌘D or the Director menu).
    private func toggleListening() {
        store.send(store.isListening ? .stopListening : .startListening)
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
