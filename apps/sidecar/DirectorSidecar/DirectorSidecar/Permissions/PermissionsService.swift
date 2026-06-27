//
//  PermissionsService.swift
//  DirectorSidecar
//
//  Track E (ADR 0005): native macOS TCC reads + grant/manage actions, folded in from
//  `apps/desktop/src-tauri/src/commands/{permissions,readiness}.rs` (the Rust FFI to
//  native_permissions.m). macOS only grants TCC in response to a real request or a
//  System-Settings toggle — an app can't grant/revoke itself — so "accept" = trigger
//  the OS prompt and "manage/revoke" = deep-link into System Settings.
//
//  The integer→PermissionState mappers are PURE and unit-tested; the live reads are a
//  thin call into AVFoundation/Speech/ApplicationServices/CoreGraphics. This is the
//  single native source of truth `ReadinessService` builds the readiness probe from.
//

import AVFoundation
import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import Speech

/// The `permissionStateSchema` vocabulary from `packages/contracts/src/readiness.ts`
/// (and the `state` strings the bridge `CapabilityProbe` carries). `unknown` is
/// reserved for "could not read it" (non-macOS / probe error).
///
/// Distinct from `SpeechService.PermissionState`, which deliberately COLLAPSES the
/// `restricted` case into `denied` for STT start-error UI. The readiness probe needs
/// the full five-way vocabulary, so this is the contract-faithful enum.
enum PermissionState: String, Codable, Sendable, Equatable, CaseIterable {
    case granted
    case denied
    case notDetermined = "not-determined"
    case restricted
    case unknown
}

/// A macOS privacy capability the user grants/manages. The rawValue matches the
/// pane string the old `open_privacy_settings` command accepted.
enum PrivacyPane: String, Sendable, CaseIterable {
    case camera
    case microphone
    case speechRecognition = "speech-recognition"
    case accessibility
    case screenRecording = "screen-recording"

    /// The `x-apple.systempreferences` anchor — the only reliable cross-version deep
    /// link (matches `permissions.rs::open_privacy_settings`).
    var settingsAnchor: String {
        switch self {
        case .camera: return "Privacy_Camera"
        case .microphone: return "Privacy_Microphone"
        case .speechRecognition: return "Privacy_SpeechRecognition"
        case .accessibility: return "Privacy_Accessibility"
        case .screenRecording: return "Privacy_ScreenCapture"
        }
    }

    /// The full System Settings URL for this pane.
    var settingsURL: URL? {
        URL(string: "x-apple.systempreferences:com.apple.preference.security?\(settingsAnchor)")
    }
}

/// The media-permission triple returned by a request round (mirrors the Rust
/// `{ "kind": "permissions", speech, microphone, camera }` payload, minus the tag —
/// the tag was a webview discriminator the native UI does not need).
struct MediaPermissions: Sendable, Equatable {
    let speech: PermissionState
    let microphone: PermissionState
    let camera: PermissionState
}

enum PermissionsService {
    // MARK: Pure status mappers (unit-tested; no FFI)

    /// `SFSpeechRecognizerAuthorizationStatus`: 0 notDetermined, 1 denied, 2 restricted,
    /// 3 authorized. NOTE the ordering differs from AVAuthorizationStatus below — the
    /// 1/2 cases are SWAPPED. Keep these two mappers separate; do not unify them.
    nonisolated static func speechState(fromRawStatus status: Int) -> PermissionState {
        switch status {
        case 0: return .notDetermined
        case 1: return .denied
        case 2: return .restricted
        case 3: return .granted
        default: return .unknown
        }
    }

    /// `AVAuthorizationStatus` (camera + microphone): 0 notDetermined, 1 restricted,
    /// 2 denied, 3 authorized.
    nonisolated static func avState(fromRawStatus status: Int) -> PermissionState {
        switch status {
        case 0: return .notDetermined
        case 1: return .restricted
        case 2: return .denied
        case 3: return .granted
        default: return .unknown
        }
    }

    // MARK: Live reads (no prompt) — the native source of truth

    static func cameraState() -> PermissionState {
        avState(fromRawStatus: Int(AVCaptureDevice.authorizationStatus(for: .video).rawValue))
    }

    static func microphoneState() -> PermissionState {
        avState(fromRawStatus: Int(AVCaptureDevice.authorizationStatus(for: .audio).rawValue))
    }

    static func speechRecognitionState() -> PermissionState {
        speechState(fromRawStatus: Int(SFSpeechRecognizer.authorizationStatus().rawValue))
    }

    /// Accessibility trust read without prompting (`AXIsProcessTrusted`). TCC exposes
    /// only trusted/untrusted here, so this is granted/denied — never `restricted`.
    static func accessibilityState() -> PermissionState {
        AXIsProcessTrusted() ? .granted : .denied
    }

    /// Screen Recording read without prompting. `CGPreflightScreenCaptureAccess()` CACHES its first
    /// result for the life of the process, so once it answers false at launch it keeps answering
    /// false even after the user grants access mid-session — only a relaunch clears it. To reflect a
    /// live grant, cross-check the window list: with Screen Recording access, other apps' on-screen
    /// windows expose `kCGWindowName`; without it macOS withholds those titles. This is a passive
    /// read (it never triggers the prompt) and is not subject to the preflight cache.
    static func screenRecordingState() -> PermissionState {
        if CGPreflightScreenCaptureAccess() { return .granted }
        return windowTitlesVisible() ? .granted : .denied
    }

    /// True when at least one other app's normal (layer-0) on-screen window exposes a non-empty
    /// title — only possible when this process holds Screen Recording access.
    private static func windowTitlesVisible() -> Bool {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let infos = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return false
        }
        let myPid = ProcessInfo.processInfo.processIdentifier
        for info in infos {
            let pid = (info[kCGWindowOwnerPID as String] as? pid_t) ?? -1
            guard pid != myPid else { continue }
            let layer = (info[kCGWindowLayer as String] as? Int) ?? 0
            guard layer == 0 else { continue } // skip dock/menubar/overlay layers
            if let name = info[kCGWindowName as String] as? String, !name.isEmpty {
                return true
            }
        }
        return false
    }

    // MARK: Grant/manage actions (trigger the OS prompt or deep-link Settings)

    /// Trigger the microphone + speech + camera prompts for any undetermined grant and
    /// return the resulting states. Already-decided permissions are read without
    /// re-prompting (the request APIs are no-ops once decided), so this is safe to call
    /// from an "Allow" button in any state. Camera is requested from the app process so
    /// the grant registers under the app's bundle id (the head-track service inherits it).
    static func requestMediaPermissions() async -> MediaPermissions {
        await requestSpeechAuthorization()
        _ = await AVCaptureDevice.requestAccess(for: .audio)
        _ = await AVCaptureDevice.requestAccess(for: .video)
        return MediaPermissions(
            speech: speechRecognitionState(),
            microphone: microphoneState(),
            camera: cameraState()
        )
    }

    /// Microphone-only (plus speech, which the listening path always needs alongside it) request,
    /// for the onboarding's per-row "Allow". Prompts any undetermined grant; no-op once decided.
    static func requestMicrophoneAndSpeech() async -> (microphone: PermissionState, speech: PermissionState) {
        await requestSpeechAuthorization()
        _ = await AVCaptureDevice.requestAccess(for: .audio)
        return (microphoneState(), speechRecognitionState())
    }

    /// Camera-only request, for the onboarding's per-row "Allow". Prompts if undetermined; the grant
    /// registers under the app's bundle id so the head-track service inherits it.
    static func requestCamera() async -> PermissionState {
        _ = await AVCaptureDevice.requestAccess(for: .video)
        return cameraState()
    }

    /// Trigger the Screen Recording prompt AND register the app in the Screen Recording
    /// list so the user can toggle it on. Unlike the read-only preflight the probe uses,
    /// this REQUESTS access. Returns whether access is already granted (a fresh grant
    /// usually needs an app relaunch). Mirrors `request_screen_recording`.
    @discardableResult
    static func requestScreenRecording() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    /// Surface the Accessibility consent prompt (no-op once decided) and return the
    /// current trust state. Shared shape with the fn-hotkey install path.
    @discardableResult
    static func promptAccessibility() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// Open the System Settings privacy pane for a capability so the user can grant or
    /// revoke it. Returns whether the URL opened. Mirrors `open_privacy_settings` but
    /// uses `NSWorkspace` instead of shelling out to `open`.
    @discardableResult
    static func openPrivacySettings(_ pane: PrivacyPane) -> Bool {
        guard let url = pane.settingsURL else { return false }
        return NSWorkspace.shared.open(url)
    }

    private static func requestSpeechAuthorization() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            SFSpeechRecognizer.requestAuthorization { _ in
                continuation.resume()
            }
        }
    }
}
