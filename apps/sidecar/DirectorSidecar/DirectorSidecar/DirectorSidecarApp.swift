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
import OSLog

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
    /// ADR 0005 Track D: the in-process engine (the ported `VoiceCuaLoop`) that replaces the
    /// loopback socket as the app's engine of record. Held for the app's whole run.
    private let engine: LoopEngine
    private let surfaces: SurfaceHost
    /// Track F: the ported engine services (CUA / speech / head pointer) and the coordinator that
    /// binds their start/stop/teardown to the app lifecycle. Held for the app's whole run.
    private let services: DirectorServices
    private let coordinator: ServiceCoordinator
    /// Face/hand migration: the single app-owned camera service (one `AVCaptureSession`, fanned to
    /// the face + hand plugins). The live face/hand owner — hand drives the `.user` cursor, face
    /// drives the gaze region — replacing the separate `HeadPointerService`/`HandLandmarkerService`
    /// camera path (those stay on disk, unused). Held for the app's whole run.
    private let perception: PerceptionService
    /// C1 fix: the global fn (Globe) capture trigger — a session-wide CGEventTap, so hold-fn-and-speak
    /// works while ANOTHER app is frontmost (the whole hands-off entry point). Replaces the old local
    /// `NSEvent` monitor that only fired while Director itself was the active app. Held for the run.
    private let fnHotkey: FnHotkeyService

    init() {
        let store = BridgeStore()
        let hud = HUDModel()
        let micro = MicroHUDModel()
        let overlay = OverlayModel()
        let gaze = GazeBracketModel()
        let home = HomeDashboardModel()
        let rail = RailModel()

        // One fan-out of every frame to every model.
        let dispatch: (BridgeFrame) -> Void = { frame in
            store.apply(frame); hud.apply(frame); micro.apply(frame)
            overlay.apply(frame); gaze.apply(frame); home.apply(frame); rail.apply(frame)
        }

        // Track F: own the ported engine services and bind them to the lifecycle. Head-pointer
        // `.point` events ride the SAME fan-out the loop uses (`cursorPosition` topic), so the
        // user's head drives the Director `.user` cursor in a non-mock run.
        let services = DirectorServices()

        // Track E→F wiring: load the persisted local config and APPLY it to the live services, so saved
        // settings take effect at launch. The head pointer runs at the SAVED speed (contract default 5,
        // not the head-track runtime default 8 it was constructed with) and the STT provider choice is
        // honored/surfaced. Recovers to the contract default if the file is missing or drifted — never
        // throws into launch. This is the documented follow-up to PORTING.md note 12 (LocalConfigService
        // was ported but, until now, read by nothing outside its tests).
        LaunchConfig.applyAtLaunch(head: services.headPointer)

        // Head/face tracking → intent. The latest head point lands in this shared snapshot (written
        // by the coordinator's head consumer below) and the loop's `HeadPointingIntake` reads it at
        // goal start — folding the head cursor + the windows it points at into the resolver input so a
        // look reaches the intent, not just the overlay cursor.
        let headSnapshot = HeadPointSnapshot()

        // Hand-gesture tracking → intent. `HeadPointingIntake` reads this shared snapshot at goal
        // start and folds the latest locked referent / wrist-ray cursor into the resolver input
        // alongside the head signal — so a hand pointed at a target reaches the intent (the gesture
        // branch of buildPointingEvidence, ported in `GestureReferentFusion`). The live producer that
        // records into it — `HandLandmarkerService` → `ReferentLoop` → `GestureReferentFusion.referent`
        // — is the camera/calibration track (its own lane, like `HeadPointerService` is for the head);
        // until it is wired the snapshot stays empty and the intake degrades to head/active-window.
        let gestureSnapshot = GestureSnapshot()

        // The live gesture producer the snapshot was waiting on. Build the ported `ReferentLoop` with
        // a DEFAULT, uncalibrated normalized→screen mapping so a pointed hand is visible before any
        // calibration flow: the wrist-ray signal is in normalized image coords ([0,1]), so an affine
        // of (a=W, e=H) spans the primary display, and one pointable Surface covers it. Contract space
        // is virtual-desktop px / top-left, and the primary sits at origin (0,0), so the mapped point
        // drops straight onto the `cursorPosition` topic the overlay renders. `HandLandmarkerService`
        // (DirectorServices) feeds this loop via the coordinator; quality is `.poor` (uncalibrated).
        let primarySize = NSScreen.screens.first?.frame.size ?? CGSize(width: 1920, height: 1080)
        let gestureSurfaces: [Contracts.Surface] = [
            Contracts.Surface(
                id: "display-primary",
                bounds: Contracts.SurfaceBounds(x: 0, y: 0, w: primarySize.width, h: primarySize.height),
                displayId: "primary",
                title: "Primary Display")
        ]
        let gestureLoop = ReferentLoop(ReferentLoopOptions(
            transform: CalibrationAffine(a: primarySize.width, b: 0, c: 0, d: 0, e: primarySize.height, f: 0),
            surfaces: gestureSurfaces,
            calibrationQuality: .poor,
            dwell: DwellDebounceParams(enter: 0.6, exit: 0.4, dwellMs: 600, cooldownMs: 1000)))

        // Face/hand migration: the one camera owner (constructed here, before the loop, so its live
        // perception NBest consumer can ground the intake). Fans each frame to the face + hand plugins:
        //   • hand → the `.user` cursor (`cursorPosition` topic) + the gesture intent snapshot
        //   • face → the gaze region (`gazeFocus` topic)         + the head-point intent snapshot
        // #150: the bus ranks each hit against the live driver window list (`windowSource`) and
        // `PointingAligner` fuses the result; the intake folds the fused top window as a leading
        // point-to-window referent. Per-display hand calibration (RB-3) is loaded for the main display
        // from the persisted profile (uncalibrated when none is stored — the capture flow is deferred).
        let calibrationRepo = CalibrationProfileRepository()
        let perception = PerceptionService(
            windowSource: { [services] in
                if case let .succeeded(windows) = await services.cua.listWindows() { return windows }
                return []
            },
            calibration: calibrationRepo.load(forDisplayID: CGMainDisplayID())?.calibrationFit()
        )

        // ADR 0005 Track D — no bridge: run the ported supervision loop IN-PROCESS and make it the
        // app's engine. The loop drives the SAME frames the socket used to deliver (engine.onFrame →
        // dispatch) and the UI's commands route to the loop (the models' command sink IS the engine).
        let loop = VoiceCuaLoop(
            driver: services.cua,
            resolve: IntentWorkerConfig.resolver(),
            intake: HeadPointingIntake(
                snapshot: headSnapshot, driver: services.cua, gesture: gestureSnapshot,
                aligner: perception.aligner, screen: perception.screen)
        )
        // Probe the cua-driver DAEMON's own TCC (accessibility/screen-recording) so readiness reflects
        // the process a task runs through — its missing grants would otherwise only surface mid-task as
        // a restart-required prompt. checkPermissions() degrades to unavailable, never throws.
        let engine = LoopEngine(loop: loop, cuaPermissionProbe: { [services] in
            if case let .succeeded(report) = await services.cua.checkPermissions() { return report }
            return nil
        })
        engine.onFrame = { frame in dispatch(frame) }
        engine.onState = { state in
            store.setConnection(state); hud.setConnection(state); micro.setConnection(state)
            overlay.setConnection(state); gaze.setConnection(state); home.setConnection(state); rail.setConnection(state)
        }
        store.bridge = engine
        home.bridge = engine
        hud.connection = engine

        // The loop's transcript trigger: live STT `.final` events start a goal; partial/final also
        // surface as HUD transcript frames. (Track F bound the mic lifecycle; this is its consumer.)
        // Face/hand migration: SPEECH-ONLY coordinator. `PerceptionService` (below) is now the live
        // camera owner for face + hand, so the coordinator no longer drives the legacy head/hand
        // cameras — it is constructed with an idle head sensor and `hand: nil`, keeping only the STT
        // lifecycle (`onSpeech` → engine). The ported `gestureLoop`/`gestureSurfaces` are still passed
        // (inert without a hand sensor) so the old hand-gesture wiring is preserved, not deleted.
        let coordinator = ServiceCoordinator(
            head: IdleHeadSensing(),
            speech: services.speech,
            hand: nil,
            loop: gestureLoop,
            gestureSurfaces: gestureSurfaces,
            onHeadPointer: { _ in },
            onHeadPoint: { _ in },
            onSpeech: { event in engine.ingestSpeech(event) },
            onGesturePointer: { _ in },
            onGestureReferent: { _ in }
        )

        // Wire the one camera owner's four callbacks (constructed above, before the loop). The bridge
        // callbacks arrive on the main thread (PerceptionService marshals them); the two intent
        // snapshots are lock-protected. Wire all four before sensing turns on.
        perception.onCursorPosition = { payload in dispatch(.cursor(pointers: payload.pointers)) }
        perception.onGazeFocus = { gaze in dispatch(.gaze(gaze)) }
        perception.onFaceEvidence = { point in headSnapshot.record(point) }
        perception.onHandEvidence = { referent in gestureSnapshot.record(referent) }

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
            if DevMockFleet.isEnabled {
                // Mock owns the cursors; the real camera/mic stay OFF so dev demos never prompt for
                // permissions or fight the mock fleet's drawn cursors.
                if DevMockFleet.runsScriptedActivation, on {
                    activation = Task { await DevMockFleet.activationLoop(dispatch: dispatch, now: Date()) }
                } else if !on {
                    dispatch(.cursor(pointers: [])) // mock: clear the agent cursors the loop drew
                }
            } else {
                if on { engine.refreshReadiness() } // re-probe TCC the moment mic/speech matter
                coordinator.setSensing(on)  // STT lifecycle
                perception.setSensing(on)   // the one camera: hand → cursor, face → gaze
            }
            #else
            if on { engine.refreshReadiness() } // re-probe TCC the moment mic/speech matter
            coordinator.setSensing(on)  // STT lifecycle
            perception.setSensing(on)   // the one camera: hand → cursor, face → gaze
            #endif
        }

        // Menu "View Activity" → bind the dashboard to THAT agent (home owns the selection + its own
        // engine send). In DEBUG mock mode, also publish that agent's plan so the inspector updates
        // immediately — no engine is there to republish the selected intent.
        store.onSelectSession = { id in
            home.select(id)
            #if DEBUG
            if DevMockFleet.isEnabled { dispatch(.intent(DevMockFleet.intent(for: id))) }
            #endif
        }

        // `store.onOpenHome` (rail ⤢ + menu "Open Home") is wired to SwiftUI's openWindow in the
        // dashboard scene (HomeOpenWiring) so it re-creates the window even after the red-X close.
        self.engine = engine
        self.store = store
        self.hud = hud
        self.micro = micro
        self.overlay = overlay
        self.gaze = gaze
        self.home = home
        self.rail = rail
        self.services = services
        self.coordinator = coordinator
        self.perception = perception

        // C1 fix: own the global fn capture trigger. Started at launch (its CGEventTap + permission
        // prompts must come up after AppKit finishes wiring event routing), with its phase stream
        // routed to the same listening commands the menu/⌥⌘D use.
        let fnHotkey = FnHotkeyService()
        self.fnHotkey = fnHotkey

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
                // C1 fix: install the global fn capture tap and route its phases to the listening
                // commands — press-hold → start/stop, double-tap → toggle. Session-wide, so this fires
                // while another app is frontmost (the entire hands-off entry point), unlike the old
                // local monitor. Falls back gracefully (logs to stderr) if Accessibility/Input
                // Monitoring aren't granted yet.
                fnHotkey.start()
                Task { @MainActor in
                    for await phase in fnHotkey.phases {
                        store.send(listeningCommand(for: phase, isListening: store.isListening))
                    }
                }
                // Track F: begin consuming the head-pointer feed for the app's life (camera stays
                // off until Listening turns sensing on). Deferred to launch alongside the surfaces.
                coordinator.start()
                perception.start()  // parity; the camera itself comes up on setSensing(true)
                // First-run permissions flow: explicitly request speech + microphone + camera so
                // the OS prompts appear and the app registers in the Speech Recognition pane (which
                // cannot be pre-granted in System Settings — the app MUST request once). Without
                // this the STT path only ever reads `notDetermined` and fails every listen with
                // "speech recognition not authorized"; the request APIs are no-ops once decided.
                Task {
                    let granted = await PermissionsService.requestMediaPermissions()
                    DirectorDiagnostics.services.info(
                        "media permissions speech=\(granted.speech.rawValue, privacy: .public) mic=\(granted.microphone.rawValue, privacy: .public) camera=\(granted.camera.rawValue, privacy: .public)")
                    // CUA needs THIS app (the process that spawns cua-driver) to hold Screen Recording:
                    // `get_window_state` captures the target window, and without that grant the driver
                    // returns an EMPTY AX tree (0 elements) — the agent sees nothing to act on and the
                    // loop just respawns launch_app. Accessibility backs the AX walk + the fn tap.
                    // Request BOTH at launch so their prompts appear UP FRONT, never mid-task (a fresh
                    // Screen Recording grant needs an app relaunch to take effect).
                    let screenRecording = PermissionsService.requestScreenRecording()
                    let accessibility = PermissionsService.promptAccessibility()
                    DirectorDiagnostics.services.info(
                        "cua permissions screen_recording=\(screenRecording ? "granted" : "denied", privacy: .public) accessibility=\(accessibility ? "granted" : "denied", privacy: .public)")
                }
            }
        }

        // Track F: release the camera/mic and finish the head stream on app quit — no leaked
        // AVCaptureSession / AVAudioEngine outliving the process.
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { coordinator.teardown(); perception.teardown() }
        }

        #if DEBUG
        if DevMockFleet.isEnabled {
            // Populate the dashboard + inspector at launch; overlays stay DOWN until you toggle
            // Listening (⌥⌘D, or the menu) — so the menu + dashboard are never obstructed. The
            // engine stays idle in mock mode (the mock fleet owns the frames); commands still
            // resolve to the engine's loop (a no-op while no goal is running).
            Task { @MainActor in
                await DevMockFleet.populate(
                    dispatch: dispatch,
                    setState: { state in store.setConnection(state); micro.setConnection(state); overlay.setConnection(state); gaze.setConnection(state); home.setConnection(state); rail.setConnection(state) },
                    select: { id in home.select(id) },
                    now: Date()
                )
                home.seedIntentions(DevMockFleet.intentionFeed(now: Date()))
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
        // G4 Home Dashboard — the product window. Single-instance `Window` (not `WindowGroup`) so the
        // red-X close + "Open Home" re-open cleanly via openWindow(id:) and never duplicate.
        Window("Director", id: "home") {
            ThemedRoot { HomeDashboardView(model: home) }
                .modifier(HomeOpenWiring(store: store, rail: rail))
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

        // G1 product entry: menu-bar status item + NATIVE pull-down menu. The `.menu` style renders
        // a real NSMenu (system liquid-glass material + native selection highlight), so MenuContent
        // only declares menu items — no custom window/blur/hover. (The label stays themed for the
        // readiness dot.)
        MenuBarExtra {
            MenuContent(store: store)
        } label: {
            ThemedRoot { MenuBarLabel(readiness: store.menuReadiness) }
        }
        .menuBarExtraStyle(.menu)
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
