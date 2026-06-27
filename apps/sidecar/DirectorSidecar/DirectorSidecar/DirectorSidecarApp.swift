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
import ApplicationServices

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
        // While the onboarding window is up, don't yank Home to the front over it — onboarding is the
        // intended front surface at first run.
        if NSApp.windows.contains(where: { $0.title == "Welcome to Director" && $0.isVisible }) { return }
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

    /// The full Listening HUD (G2 floating "LISTENING / Intent / esc" panel) is parked — it surfaced
    /// on active-agent selection where it served no purpose, so it's archived out of every visible
    /// flow. `HUDModel`, `HUDPanel`, and `ListeningHUDView` stay in the tree (still fanned frames,
    /// still under test); only the panel controller is withheld. Flip to `true` to bring it back.
    static let showsFullHUD = false

    private var started = false

    private var hud: HUDPanelController?
    private var micro: MicroHUDController?
    private var overlay: OverlayController?

    private var railController: RailController?

    func start(hud hudModel: HUDModel, micro microModel: MicroHUDModel,
               overlay overlayModel: OverlayModel, gaze: GazeBracketModel,
               rail railModel: RailModel, store: BridgeStore,
               railEdge: RailController.Edge,
               onOpenHome: @escaping () -> Void) {
        guard !started else { return }   // once only
        started = true
        if Self.showsFullHUD {
            hud = HUDPanelController(model: hudModel, edge: .trailing)
        }
        if Self.showsMicroHUD {
            micro = MicroHUDController(model: microModel, fullHUD: hudModel, onOpenHome: onOpenHome)
        }
        overlay = OverlayController(model: overlayModel, gaze: gaze)
        // The rail — the always-on ambient edge surface (replaces the parked micro-HUD). It drives
        // its own actions (deactivate / view activity / pause / open) through the store. Starts on the
        // persisted onboarding edge (right by default).
        railController = RailController(model: railModel, edge: railEdge, store: store)
    }

    /// Flip the live rail to the left/right edge — wired to the onboarding listening-edge picker.
    func setRailEdge(_ edge: RailController.Edge) {
        railController?.setEdge(edge)
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
    /// Flow to First Run — the after-download onboarding journey (welcome → primer → permissions →
    /// ready). Owns its own state; wired to the real permission + rail systems via injected actions.
    let onboarding: OnboardingModel
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

        // ADR 0005 Track D — no bridge: run the ported supervision loop IN-PROCESS and make it the
        // app's engine. The loop drives the SAME frames the socket used to deliver (engine.onFrame →
        // dispatch) and the UI's commands route to the loop (the models' command sink IS the engine).
        let replayStore = SupervisionReplayStore.applicationSupport()
        // #148: dispatch through the HYBRID actuator — IN-PROCESS native AX (the app's own Accessibility
        // grant) is the DEFAULT for click/type/set_value + window reads; the `cua-driver` is the
        // fallback only for AX-opaque surfaces. The native window source (#150) decouples point→window
        // targeting from the driver's empty bundled list.
        let actionDriver = HybridActuator(
            inner: services.cua, nativeWindows: { NativeWindowSource.onScreenWindows() })
        let loop = VoiceCuaLoop(
            driver: actionDriver,
            resolve: IntentWorkerConfig.resolver(),
            intake: HeadPointingIntake(snapshot: headSnapshot, driver: services.cua, gesture: gestureSnapshot),
            replayStore: replayStore
        )
        // Probe the cua-driver DAEMON's own TCC (accessibility/screen-recording) so readiness reflects
        // the process a task runs through — its missing grants would otherwise only surface mid-task as
        // a restart-required prompt. checkPermissions() degrades to unavailable, never throws.
        let engine = LoopEngine(loop: loop, cuaPermissionProbe: { [services] in
            if case let .succeeded(report) = await services.cua.checkPermissions() { return report }
            return nil
        }, replayStore: replayStore)
        engine.onFrame = { frame in dispatch(frame) }
        engine.onState = { state in
            store.setConnection(state); hud.setConnection(state); micro.setConnection(state)
            overlay.setConnection(state); gaze.setConnection(state); home.setConnection(state); rail.setConnection(state)
        }
        store.bridge = engine
        home.bridge = engine
        hud.connection = engine

        // Beat 1 — the look+voice formatted-drop flow ("Hey Director, copy this" → "…drop it here").
        // Wire the pure `VoiceActionCoordinator` to the real subsystems: the gaze point comes from the
        // shared head snapshot, text/frame from the in-process AX resolver (#148, the Director's own
        // grant), the clipboard from `FormattedClipboard`, the paste from `NativeAXActuation`, and the
        // element brackets ride the same `gazeFocus` fan-out the gaze CV uses.
        //
        // Owner gate: `.auditedBypass` for the live demo — there is no voiceprint source yet, so every
        // verify returns `.bypassed` (LOGGED, never a silent admit). Swapping to `.enforce` plus a real
        // embedding source (a speaker-encoder over the STT audio) is the remaining live-backend
        // dependency before this gates on the owner's voice.
        let beat1OwnerGate = OwnerGate(mode: .auditedBypass)
        // The tamper-evident sink for owner-gate decisions: an `.auditedBypass` (or a denial) is
        // appended to the SHA-256 hash-chained AuditLog in ADDITION to OSLog, so the bypass is
        // discoverable in an immutable chain — not only in a forgeable log stream.
        let beat1AuditLog = AuditLog()
        let voiceCoordinator = VoiceActionCoordinator(environment: VoiceActionEnvironment(
            currentPoint: {
                guard let p = headSnapshot.current else { return nil }
                return CGPoint(x: p.x, y: p.y)
            },
            readText: { point in
                guard let element = AXElementResolver.element(at: point) else { return nil }
                return AXElementResolver.readString(element, kAXSelectedTextAttribute as String)
                    ?? AXElementResolver.readString(element, kAXValueAttribute as String)
            },
            elementFrame: { point in
                guard let element = AXElementResolver.element(at: point) else { return nil }
                return AXElementResolver.frame(of: element)
            },
            writeClipboard: { content in FormattedClipboard.write(content) },
            focusElement: { point in
                // Shift keyboard focus to the gazed element so Cmd+V lands in it. Prefer AX focus
                // (places the caret in a text field); fall back to the element's native press, then to
                // a synthesized left-click at the point (mirrors NativeAXActuation's CGEvent style).
                // Best-effort — a `false` is logged by the coordinator but never aborts the paste.
                guard let element = AXElementResolver.element(at: point) else {
                    return postFocusClick(at: point)
                }
                if AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success {
                    return true
                }
                if AXElementResolver.press(element) { return true }
                return postFocusClick(at: point)
            },
            paste: { NativeAXActuation.postPaste() },
            showBrackets: { rect, _ in
                // Render element-sized gaze brackets over the captured/targeted region. AX frames are
                // CG-global top-left and `GazeRegion` is virtual-desktop px top-left — the same space.
                let focus = GazeFocus(
                    bounds: GazeRegion(x: rect.origin.x, y: rect.origin.y, w: rect.width, h: rect.height),
                    confidence: 1.0,
                    sizeClass: "element",
                    ts: Date().timeIntervalSince1970 * 1000)
                dispatch(.gaze(focus))
            },
            ownerVerify: { beat1OwnerGate.verify([]) },
            log: { message in DirectorDiagnostics.loop.info("\(message, privacy: .public)") },
            audit: { action in
                // Append a tamper-evident record of the owner-gate decision. The id is a deterministic
                // sequence (the current chain length) — NOT a clock/random value — so it's stable and
                // unique per commit. `append` stamps prevHash/hash, so "" placeholders are fine here.
                let seq = beat1AuditLog.count
                beat1AuditLog.append(AuditEntry(
                    action: action,
                    args: [],
                    taint: .trusted,
                    conf: 0,
                    verified: false,
                    undoToken: UndoToken(id: "owner-gate-\(seq)", action: "owner-gate"),
                    prevHash: "",
                    hash: ""))
            }
        ))
        // A consumed Beat 1 command does not also start a goal (see LoopEngine.ingestSpeech). The hook
        // is invoked from the main-actor speech intake; the coordinator is @MainActor.
        engine.voiceAction = { [voiceCoordinator] text in
            voiceCoordinator.handle(transcript: text)
        }

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

        // Face/hand migration: the one camera owner. Fans each frame to the face + hand plugins:
        //   • hand → the `.user` cursor (`cursorPosition` topic) + the gesture intent snapshot
        //   • face → the gaze region (`gazeFocus` topic)         + the head-point intent snapshot
        // The bridge callbacks arrive on the main thread (PerceptionService marshals them); the two
        // snapshots are lock-protected. Wire all four before sensing turns on.
        let perception = PerceptionService()
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

        // Menu "Settings…" → open the dashboard on its Settings tab.
        store.onOpenSettings = { home.tab = .settings; store.onOpenHome?() }

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

        // Flow to First Run model — wired to the REAL systems: the CUA driver check, the live rail
        // controller (edge flip), and Home. Permissions are read/triggered directly via
        // PermissionsService inside the model.
        self.onboarding = OnboardingModel(actions: OnboardingModel.Actions(
            checkCua: {
                switch await services.cua.checkPermissions() {
                case let .succeeded(report):
                    let ready = report.driver == .running
                        && report.accessibility == .granted
                        && report.screenRecording == .granted
                    let detail = ready
                        ? "Daemon running · screen + accessibility ready."
                        : "Daemon \(report.driver.rawValue) · grants pending."
                    return (ready, detail)
                case let .failed(error):
                    return (false, "Engine check failed: \(error)")
                case let .blocked(reason):
                    return (false, "Engine blocked: \(reason)")
                }
            },
            applyRailEdge: { edge in surfaces.setRailEdge(edge.controllerEdge) }
        ))

        // The unit-test target is HOSTED in this app, so launching to run the tests fires the full
        // app lifecycle. On a headless CI runner (no camera / accessibility / interactive window
        // server) the live services — PerceptionService's AVCaptureSession, the fn CGEventTap, the
        // always-on-top panels — BLOCK, hanging the entire hosted test run (the swift CI job timed
        // out at ~103m once #157 made PerceptionService the live owner). Skip ALL live startup under
        // XCTest; unit tests construct exactly what they need directly.
        let isRunningUnderTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

        NotificationCenter.default.addObserver(
            forName: NSApplication.didFinishLaunchingNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                guard !isRunningUnderTests else { return }
                surfaces.start(hud: hud, micro: micro, overlay: overlay, gaze: gaze, rail: rail,
                               store: store, railEdge: AppPreferences.railEdge.controllerEdge,
                               onOpenHome: { store.send(.openHome) })
                // The global fn capture tap needs Accessibility + Input Monitoring, so installing it
                // PROMPTS the user. DEFER it until they've actually entered the app (Home appeared,
                // i.e. onboarding finished or was skipped) — so first launch shows ONLY the Welcome
                // window, never a system permission dialog over it. Permissions during onboarding come
                // exclusively from its own Allow buttons. Idempotent; one consumer of the phase stream.
                var fnStarted = false
                let startFnCapture = {
                    guard !fnStarted else { return }
                    fnStarted = true
                    fnHotkey.start()
                    Task { @MainActor in
                        for await phase in fnHotkey.phases {
                            store.send(listeningCommand(for: phase, isListening: store.isListening))
                        }
                    }
                }
                NotificationCenter.default.addObserver(
                    forName: .directorEnterApp, object: nil, queue: .main
                ) { _ in MainActor.assumeIsolated { startFnCapture() } }
                // Track F: begin consuming the head-pointer feed for the app's life (camera stays
                // off until Listening turns sensing on). Deferred to launch alongside the surfaces.
                coordinator.start()
                perception.start()  // parity; the camera itself comes up on setSensing(true)
                // First-run permissions flow: explicitly request speech + microphone + camera so
                // the OS prompts appear and the app registers in the Speech Recognition pane (which
                // cannot be pre-granted in System Settings — the app MUST request once). Without
                // this the STT path only ever reads `notDetermined` and fails every listen with
                // "speech recognition not authorized"; the request APIs are no-ops once decided.
                // Onboarding (when shown) drives permissions via its own buttons, so only auto-prompt
                // at launch when the onboarding window is NOT showing — avoids a double prompt.
                if !OnboardingGate.shouldShowAtLaunch {
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
        } else if !isRunningUnderTests {
            engine.start()
        }
        #else
        if !isRunningUnderTests { engine.start() }
        #endif
    }

    /// Toggle the listening overlays from anywhere in the app (⌥⌘D or the Director menu).
    private func toggleListening() {
        store.send(store.isListening ? .stopListening : .startListening)
    }

    var body: some Scene {
        // Flow to First Run — the after-download onboarding window. Declared FIRST so it is the only
        // window that auto-opens at launch (Home stays closed until onboarding completes). Content-
        // sized, hidden titlebar (macOS still draws the traffic lights), centered. It opens Home and
        // closes itself on finish; if onboarding isn't wanted (completed + always-show off) it bounces
        // straight to Home on appear.
        Window("Welcome to Director", id: OnboardingScene.id) {
            ThemedRoot { OnboardingView(model: onboarding) }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        // G4 Home Dashboard — the product window. Single-instance `Window` (not `WindowGroup`) so the
        // red-X close + "Open Home" re-open cleanly via openWindow(id:) and never duplicate. Opens
        // only after onboarding finishes (or directly when onboarding is disabled).
        Window("Director", id: "home") {
            ThemedRoot { HomeDashboardView(model: home, store: store) }
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

extension Notification.Name {
    /// Posted when the user enters the app proper (the Home window appears, post-onboarding). Gates
    /// the deferred startup of permission-prompting services (the fn capture tap) so first launch is
    /// only the Welcome window.
    static let directorEnterApp = Notification.Name("DirectorEnterApp")
}

/// Best-effort focus click — a synthesized left-click at a CG-global point to place the keyboard caret
/// when AX focus/press is unavailable (mirrors `NativeAXActuation`'s CGEvent style). Returns whether
/// the events were posted; the Beat 1 paste path treats a `false` as non-fatal (logged, not aborting).
private func postFocusClick(at point: CGPoint) -> Bool {
    guard let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown,
                             mouseCursorPosition: point, mouseButton: .left),
          let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp,
                           mouseCursorPosition: point, mouseButton: .left) else {
        return false
    }
    down.post(tap: .cghidEventTap)
    up.post(tap: .cghidEventTap)
    return true
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
                // Home is showing → its minimized echo (the rail) hides. (Home only ever appears once
                // onboarding has finished and opened it, so no onboarding coordination is needed here.)
                rail.setHomeOpen(true)
                // Entering the app proper — now it's appropriate to install the fn capture tap (which
                // prompts for Accessibility/Input Monitoring). Deferred from launch so onboarding owns
                // the permission UX. Idempotent on the listener side.
                NotificationCenter.default.post(name: .directorEnterApp, object: nil)
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
