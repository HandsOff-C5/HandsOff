//
//  DirectorServices.swift
//  DirectorSidecar
//
//  Track F (ADR 0005 — wire services into the Swift app). The composition container for the three
//  ported engine services, matching PORTING.md's documented `DirectorServices` shape. Before this,
//  each service was ported but instantiated NOWHERE — orphaned. This is the single place the app
//  builds them so their lifecycle can be bound to the app (see `ServiceCoordinator`).
//
//  Divergence from PORTING.md's aspirational `cua/readiness/speech/hotkey/overlay/headPointer`
//  shape is deliberate: this codebase does not (yet) have standalone `readiness`/`overlay`
//  service objects — readiness is derived from `cua.checkPermissions()` + the engine bridge, and
//  the overlay is the already-wired `OverlayController`/`OverlayModel`. The hotkey IS a real ported
//  service (`FnHotkeyService`, the global fn CGEventTap) but the app owns it directly (instantiated
//  in `DirectorSidecarApp`) rather than through this container. Only the three engine-lifecycle
//  services (cua / speech / head pointer) the coordinator binds live here; fabricating
//  empty service slots would be a dead surface (the same "no unfed surface" rule the overlay/
//  head-track folds followed).
//

import Foundation

/// The long-lived engine services the app owns for its whole run. Built once in `App.init()` and
/// handed to a `ServiceCoordinator`, which binds their start/stop/teardown to the app lifecycle.
///
/// `@MainActor` because it is assembled and held from the SwiftUI `App` (the main actor). The
/// services themselves keep their own isolation: `cua` is an `actor`, `headPointer` runs its own
/// camera/video queues (`nonisolated`/`@unchecked Sendable`), and `speech` is `@MainActor`.
@MainActor
struct DirectorServices {
    /// `cua-driver` Process adapter — the read/perception/catalog/generic surface AND the native
    /// readiness source (`checkPermissions()`), since Rust's TCC checks moved here.
    let cua: CuaDriverService

    /// On-device STT stream (SFSpeechRecognizer / SpeechAnalyzer). The hosted-token path is the
    /// `SpeechService` namespace's static surface; this is the streaming session the app drives.
    let speech: SpeechService.OnDeviceStream

    /// In-process front-camera head pointer — the folded-in `head-track` sidecar. Its `.point`
    /// events are the real source of the Director (`.user`) cursor in a non-mock run.
    let headPointer: HeadPointerService

    /// In-process front-camera hand landmarker (Vision `VNDetectHumanHandPoseRequest`) — the live
    /// SOURCE of the ported gesture pipeline. Its `DetectionResult` frames drive the
    /// `ReferentLoop` so a pointed hand moves the Director cursor and grounds the intent (the seam
    /// `GestureReferentFusion`/`GestureSnapshot` were waiting on). Runs its own session alongside
    /// `headPointer`; the coordinator arbitrates hand-over-head for the cursor.
    let handPointer: HandLandmarkerService

    init(
        cua: CuaDriverService,
        speech: SpeechService.OnDeviceStream,
        headPointer: HeadPointerService,
        handPointer: HandLandmarkerService
    ) {
        self.cua = cua
        self.speech = speech
        self.headPointer = headPointer
        self.handPointer = handPointer
    }

    /// Build the real services. Kept as a no-argument init (not default arguments) because
    /// `SpeechService.OnDeviceStream` is `@MainActor`-isolated: a default-argument expression
    /// evaluates in a NONISOLATED context, so `= SpeechService.OnDeviceStream()` fails to compile
    /// even on a `@MainActor` struct. Constructing it inside this `@MainActor` init body is fine.
    init() {
        self.init(
            cua: CuaDriverService(),
            speech: SpeechService.OnDeviceStream(),
            headPointer: HeadPointerService(),
            handPointer: HandLandmarkerService()
        )
    }
}
