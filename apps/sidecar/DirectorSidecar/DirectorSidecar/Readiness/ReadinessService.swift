//
//  ReadinessService.swift
//  DirectorSidecar
//
//  Track E (ADR 0005): the native first-run capability probe, folded in from
//  `apps/desktop/src-tauri/src/commands/readiness.rs::readiness_payload()`. The ADR
//  makes readiness the NATIVE source of truth: instead of asking the loopback engine
//  bridge for `getReadiness`, the Swift app now reads macOS TCC directly through
//  `PermissionsService` and builds the same `ReadinessPayload` the dashboard renders.
//
//  Produces the existing `ReadinessPayload`/`CapabilityProbe` wire types (BridgeTypes.swift)
//  so the consumer can swap `BridgeClient.requestReadiness()` for `ReadinessService.probe()`
//  with zero downstream type change. The capability SET and ORDER mirror the Rust payload
//  and the contract `CAPABILITY_IDS` exactly, so the six tiles can never drift.
//

import Foundation

enum ReadinessService {
    /// The six capabilities, in the same order as `CAPABILITY_IDS`
    /// (packages/contracts/src/readiness.ts) and the Rust `readiness_payload()`.
    /// `cua` is a `daemon` capability whose probe lives in the CUA lane, so it stays
    /// `unknown` here (the Rust payload hardcodes `unknown` too).
    nonisolated static func payload(
        camera: PermissionState,
        microphone: PermissionState,
        speechRecognition: PermissionState,
        accessibility: PermissionState,
        screenRecording: PermissionState
    ) -> ReadinessPayload {
        ReadinessPayload(capabilities: [
            CapabilityProbe(id: "camera", kind: "permission", state: camera.rawValue),
            CapabilityProbe(id: "microphone", kind: "permission", state: microphone.rawValue),
            CapabilityProbe(id: "speech-recognition", kind: "permission", state: speechRecognition.rawValue),
            CapabilityProbe(id: "cua", kind: "daemon", state: "unknown"),
            CapabilityProbe(id: "accessibility", kind: "permission", state: accessibility.rawValue),
            CapabilityProbe(id: "screen-recording", kind: "permission", state: screenRecording.rawValue),
        ])
    }

    /// Read live macOS TCC state and build the readiness probe. Read-only — never
    /// prompts (matches the Rust `readiness_probe` command).
    static func probe() -> ReadinessPayload {
        payload(
            camera: PermissionsService.cameraState(),
            microphone: PermissionsService.microphoneState(),
            speechRecognition: PermissionsService.speechRecognitionState(),
            accessibility: PermissionsService.accessibilityState(),
            screenRecording: PermissionsService.screenRecordingState()
        )
    }

    /// Overlay the cua-driver DAEMON's own TCC report onto a base probe — the `accessibility`,
    /// `screen-recording`, and `cua` tiles. This matters because the daemon (`com.trycua.driver`,
    /// a separate `/Applications/CuaDriver.app` reparented to launchd) is its OWN responsible process:
    /// it — not Director — performs the AX actions + screen reads a task needs, so ITS grant is the one
    /// that gates a CUA task. Reading Director's own `AXIsProcessTrusted`/`CGPreflight…` (the base
    /// probe) would green-light a task the daemon can't actually run, and the user only discovers the
    /// missing grant mid-task (with a restart-required prompt). Camera/microphone/speech stay the base
    /// probe's (Director holds those, for STT + head tracking).
    nonisolated static func merging(
        _ base: ReadinessPayload, cuaReport: CuaPermissionReport
    ) -> ReadinessPayload {
        let accessibility = (PermissionState(rawValue: cuaReport.accessibility.rawValue) ?? .unknown).rawValue
        let screenRecording = (PermissionState(rawValue: cuaReport.screenRecording.rawValue) ?? .unknown).rawValue
        let cua = cuaDaemonState(cuaReport.driver)
        let updated = base.capabilities.map { capability -> CapabilityProbe in
            switch capability.id {
            case "accessibility": return CapabilityProbe(id: capability.id, kind: capability.kind, state: accessibility)
            case "screen-recording": return CapabilityProbe(id: capability.id, kind: capability.kind, state: screenRecording)
            case "cua": return CapabilityProbe(id: capability.id, kind: capability.kind, state: cua)
            default: return capability
            }
        }
        return ReadinessPayload(capabilities: updated)
    }

    /// Map the daemon liveness to the `cua` capability `state` string the menu/dashboard read
    /// (`running` is the healthy daemon state, matching `CapabilityProbe(kind: "daemon")`).
    nonisolated static func cuaDaemonState(_ status: CuaDriverStatus) -> String {
        switch status {
        case .running: return "running"
        case .unavailable: return "stopped"
        case .unknown: return "unknown"
        }
    }
}
