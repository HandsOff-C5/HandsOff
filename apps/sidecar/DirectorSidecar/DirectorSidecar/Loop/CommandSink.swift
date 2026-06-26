//
//  CommandSink.swift
//  DirectorSidecar
//
//  ADR 0005 Track D ("bridge or no-bridge" → no-bridge, temporary path). The one seam the UI
//  models send commands through. Historically this was the loopback socket `BridgeConnection`
//  (the engine lived in a hidden TypeScript process); with the loop ported in-process
//  (`VoiceCuaLoop`), the sink becomes `LoopEngine`, which calls the loop directly — no bridge
//  expansion. The models depend on THIS protocol, not on a concrete transport, so the engine
//  swap is a one-line type change per model and a fake sink drops in under test.
//
//  `async` because a sink may cross an isolation boundary (the legacy actor socket did; the
//  in-process engine hops to the main actor). `Sendable` so `any CommandSink` can be stored on
//  the @MainActor view models and captured into the send Task.
//

import Foundation

protocol CommandSink: Sendable {
    func send(_ command: Command) async
}
