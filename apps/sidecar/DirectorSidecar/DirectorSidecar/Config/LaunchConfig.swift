//
//  LaunchConfig.swift
//  DirectorSidecar
//
//  Track E → Track F wiring (ADR 0005). The persisted `LocalConfig` (LocalConfigService) was ported
//  but read by NOTHING outside its own tests, so saved Head Pointer + STT settings had no effect: the
//  head pointer ran at the head-track RUNTIME default (`HeadPointerConfig.default.speed == 8`) instead
//  of the persisted CONTRACT value (`LocalConfig.default.headPointer.speed == 5`), and `sttProvider`
//  was ignored. This is the launch seam that loads the config and applies it to the running services —
//  the documented follow-up to PORTING.md note 12 ("Not wired into the app here").
//
//  Faithful to the old desktop startup: the frontend loaded `load_local_config` once at launch, fed
//  `headPointer` to the head-track sidecar, and chose the STT stream via `streamFactoryFor(sttProvider)`
//  (apps/desktop/src/screens/dashboard/Dashboard.tsx). Here the head config goes straight to
//  `HeadPointerService.applyConfig`, and the provider resolves through `SpeechProviderResolution`. Only
//  the on-device (`native`) stream is ported; the hosted realtime path (`assemblyai`, the old
//  `createRealtimeStream`) is a separate follow-up port, so selecting it degrades to on-device —
//  surfaced in the launch log, never silently ignored.
//

import Foundation
import OSLog

/// The head-pointer config seam the launch path drives. `HeadPointerService` already has this exact
/// method; the protocol exists only to inject a recording fake under headless test — a real service's
/// applied config lives on its private video queue with no getter (and no camera runs under
/// `xcodebuild`). Mirrors how `ServiceCoordinator` injects `HeadSensing`/`SpeechStreaming`.
@MainActor
protocol HeadPointerConfigSink: AnyObject {
    func applyConfig(_ config: HeadPointerConfig)
}

extension HeadPointerService: HeadPointerConfigSink {}

/// How a persisted `sttProvider` resolves to a runnable STT stream in THIS app — the faithful analogue
/// of the old `streamFactoryFor`. Only the on-device path is ported, so the hosted realtime path
/// degrades honestly (with a reason) rather than silently doing nothing.
enum SpeechProviderResolution: Equatable {
    /// `native` → the ported on-device stream (`SpeechService.OnDeviceStream`: SFSpeechRecognizer /
    /// SpeechAnalyzer). The default, and the only fully-honored provider today.
    case onDevice
    /// `assemblyai` selected, but the hosted realtime Swift stream is not ported yet — running
    /// on-device until it lands. The choice is honored to the extent the ported code allows.
    case onDeviceDegraded

    static func resolve(_ provider: SttProvider) -> SpeechProviderResolution {
        switch provider {
        case .native: return .onDevice
        case .assemblyai: return .onDeviceDegraded
        }
    }

    /// A one-line summary for the launch log so the resolved provider is observable — in particular so
    /// a degraded `assemblyai` selection is surfaced, not silently swallowed.
    var logSummary: String {
        switch self {
        case .onDevice:
            return "stt=native (on-device)"
        case .onDeviceDegraded:
            return "stt=assemblyai selected, but hosted realtime STT is not yet ported to the native app — running on-device"
        }
    }
}

@MainActor
enum LaunchConfig {
    /// What `applyAtLaunch` loaded and how the provider resolved — returned for diagnostics and tests.
    struct Applied: Equatable {
        let config: LocalConfig
        let speech: SpeechProviderResolution
    }

    /// Load the persisted local config and apply it to the running services at launch:
    ///   - `headPointer` → `HeadPointerService.applyConfig`, so the head pointer runs at the SAVED speed
    ///     (contract default **5**), overriding the head-track RUNTIME default of **8** that constructed
    ///     the service — the speed-8-not-5 regression.
    ///   - `sttProvider` → resolved through `SpeechProviderResolution` so the choice is honored/surfaced.
    ///
    /// Recovers to the contract default on ANY load failure — launch must never throw, exactly as the
    /// Rust `load_config_at_path` recovered-to-default. The default itself carries the contract speed (5),
    /// so even a fresh install applies 5, not the runtime 8.
    @discardableResult
    static func applyAtLaunch(
        head: HeadPointerConfigSink,
        load: () throws -> LocalConfig = LocalConfigService.load
    ) -> Applied {
        let config = (try? load()) ?? .default
        head.applyConfig(config.headPointer)
        let speech = SpeechProviderResolution.resolve(config.sttProvider)
        DirectorDiagnostics.services.info(
            "local config applied: head movementMode=\(config.headPointer.movementMode.rawValue, privacy: .public) speed=\(config.headPointer.speed, privacy: .public) distanceToEdge=\(config.headPointer.distanceToEdge, privacy: .public); \(speech.logSummary, privacy: .public)")
        return Applied(config: config, speech: speech)
    }
}
