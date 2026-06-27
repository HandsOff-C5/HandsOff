//
//  OnboardingModel.swift
//  DirectorSidecar
//
//  State + behavior for the Flow-to-First-Run onboarding. Four steps (welcome → primer →
//  permissions → ready). Permission rows read LIVE TCC status from PermissionsService and trigger
//  the REAL OS prompts; the CUA health row runs the real driver check; the rail-edge picker applies
//  and persists immediately. All side effects that need app-level objects (the engine's CUA check,
//  the live rail controller, opening Home, closing this window) arrive as injected closures so the
//  model itself stays free of the composition root.
//

import SwiftUI
import Observation

@MainActor
@Observable
final class OnboardingModel {
    /// The four window views, in order. `rawValue` doubles as the progress-dot index.
    enum Step: Int, CaseIterable { case welcome = 0, primer, permissions, ready }

    enum CuaPhase: Equatable { case idle, checking, ready, needsGrants }

    // MARK: injected side effects (composition root wires these)

    struct Actions {
        /// Run the real `services.cua.checkPermissions()` and report ready + a short status line.
        var checkCua: () async -> (ready: Bool, detail: String)
        /// Apply the chosen edge to the live rail panel (re-anchors immediately).
        var applyRailEdge: (RailEdge) -> Void
    }

    private let actions: Actions

    // MARK: observable state

    private(set) var step: Step = .welcome

    private(set) var screen: PermissionState = .notDetermined
    private(set) var accessibility: PermissionState = .notDetermined
    private(set) var microphone: PermissionState = .notDetermined
    private(set) var camera: PermissionState = .notDetermined
    /// Screen Recording usually needs an app relaunch before the grant reads back as granted, so we
    /// track "the prompt was triggered" separately to avoid trapping the user on this one row.
    private(set) var screenRequested = false

    private(set) var cua: CuaPhase = .idle
    private(set) var cuaDetail = "Daemon not checked yet."

    var railEdge: RailEdge

    /// Set true briefly to nudge a dimmed Continue (caught by the view to shake the button).
    private(set) var continueBump = 0

    init(actions: Actions) {
        self.actions = actions
        self.railEdge = AppPreferences.railEdge
        refreshPermissions()
    }

    // MARK: navigation

    func goNext() { advance(by: 1) }
    func goBack() { advance(by: -1) }

    private func advance(by delta: Int) {
        let next = max(0, min(Step.allCases.count - 1, step.rawValue + delta))
        step = Step(rawValue: next) ?? step
        if step == .permissions { refreshPermissions() }
    }

    // MARK: permissions

    /// Re-read every grant from TCC (no prompt). Called on entering the permissions step, after
    /// every request, and when the app reactivates (e.g. user returns from System Settings).
    func refreshPermissions() {
        screen = PermissionsService.screenRecordingState()
        accessibility = PermissionsService.accessibilityState()
        microphone = PermissionsService.microphoneState()
        camera = PermissionsService.cameraState()
    }

    func allowScreen() {
        screenRequested = true
        PermissionsService.requestScreenRecording()
        // Grant may need a relaunch; deep-link Settings so the toggle is one click away.
        if PermissionsService.screenRecordingState() != .granted {
            PermissionsService.openPrivacySettings(.screenRecording)
        }
        refreshPermissions()
    }

    func allowAccessibility() {
        PermissionsService.promptAccessibility()
        if PermissionsService.accessibilityState() != .granted {
            PermissionsService.openPrivacySettings(.accessibility)
        }
        refreshPermissions()
    }

    func allowMicrophone() async {
        _ = await PermissionsService.requestMicrophoneAndSpeech()
        refreshPermissions()
    }

    func allowCamera() async {
        _ = await PermissionsService.requestCamera()
        refreshPermissions()
    }

    /// "Allow All": fire every real request in sequence, then run the CUA check. Screen + accessibility
    /// open System Settings if still ungranted (they need a manual toggle / relaunch).
    func allowAll() async {
        screenRequested = true
        PermissionsService.requestScreenRecording()
        PermissionsService.promptAccessibility()
        _ = await PermissionsService.requestMicrophoneAndSpeech()
        _ = await PermissionsService.requestCamera()
        refreshPermissions()
        if screen != .granted { PermissionsService.openPrivacySettings(.screenRecording) }
        else if accessibility != .granted { PermissionsService.openPrivacySettings(.accessibility) }
        await runCuaCheck()
    }

    func runCuaCheck() async {
        guard cua != .checking else { return }
        cua = .checking
        cuaDetail = "Verifying daemon, permissions, apps…"
        let result = await actions.checkCua()
        cua = result.ready ? .ready : .needsGrants
        cuaDetail = result.detail
    }

    /// The grants that CAN flip live in-session (mic/camera/accessibility) must be granted; Screen
    /// Recording is best-effort (granted, or requested and pending a relaunch) so it can't trap.
    var canContinue: Bool {
        microphone == .granted && camera == .granted && accessibility == .granted
            && (screen == .granted || screenRequested)
    }

    func tryContinue() {
        if canContinue { advance(by: 1) }
        else { continueBump += 1 }
    }

    /// Escape hatch: jump to the Ready step regardless of grant state. For iterating on the rest of
    /// the journey + getting into the app when a permission can't read live (signature reset, the
    /// screen-recording relaunch quirk) or a backend like the CUA daemon isn't built yet.
    func skip() { step = .ready }

    func isGranted(_ state: PermissionState) -> Bool { state == .granted }

    // MARK: rail edge

    func pickEdge(_ edge: RailEdge) {
        guard edge != railEdge else { return }
        railEdge = edge
        AppPreferences.railEdge = edge
        actions.applyRailEdge(edge)
    }

    // MARK: finish

    /// Persist completion + edge and apply the edge live. The view drives the window transition
    /// (open Home, close onboarding) since it owns openWindow/dismissWindow.
    func finish() {
        AppPreferences.onboardingCompleted = true
        AppPreferences.railEdge = railEdge
        actions.applyRailEdge(railEdge)
    }
}
