//
//  LaunchConfigTests.swift
//  DirectorSidecarTests
//
//  The launch seam that was missing (PORTING.md note 12 follow-up): loading the persisted `LocalConfig`
//  and APPLYING it to the running services. Pins the speed-8-not-5 regression — a fresh/missing/failed
//  load applies the CONTRACT default speed 5, NEVER the head-track RUNTIME default 8 the service is
//  constructed with — and the STT-provider honoring. Uses a recording fake for the head-pointer sink:
//  a real `HeadPointerService` keeps its applied config on a private video queue with no getter, and
//  can't run a camera under headless `xcodebuild` (same reason `ServiceCoordinatorTests` fakes the
//  sensors). One end-to-end case drives the REAL `LocalConfigService` loader off a temp-dir file.
//

import Testing
import Foundation
@testable import DirectorSidecar

@MainActor
private final class FakeHeadConfigSink: HeadPointerConfigSink {
    private(set) var applied: [HeadPointerConfig] = []
    func applyConfig(_ config: HeadPointerConfig) { applied.append(config) }
}

@MainActor
@Test func missingOrFailedLoadRecoversToContractDefaultSpeedFiveNotEight() {
    let head = FakeHeadConfigSink()
    // A load that fails (missing file / undecodable) must recover to the contract default, never throw.
    let applied = LaunchConfig.applyAtLaunch(head: head, load: { throw LocalConfigError.readFailed("missing") })

    #expect(applied.config == .default)
    #expect(head.applied.count == 1)
    // The regression: the persisted/contract speed is 5, NOT the head-track runtime default of 8 that
    // constructed the service. Pin BOTH sides so the divergence can't silently collapse.
    #expect(head.applied.first?.speed == 5)
    #expect(head.applied.first?.speed != HeadPointerConfig.default.speed)   // 8 — the value that leaked through before the fix
    #expect(HeadPointerConfig.default.speed == 8)
    #expect(applied.speech == .onDevice)                                    // default provider is native
}

@MainActor
@Test func persistedHeadPointerConfigReachesTheService() {
    let head = FakeHeadConfigSink()
    let saved = LocalConfig(
        sttProvider: .native,
        headPointer: HeadPointerConfig(movementMode: .relative, speed: 12, distanceToEdge: 0.3))
    let applied = LaunchConfig.applyAtLaunch(head: head, load: { saved })

    #expect(applied.config == saved)
    #expect(head.applied.first == saved.headPointer)   // the SAVED head config — verbatim — reaches the service
    #expect(head.applied.first?.speed == 12)
    #expect(head.applied.first?.movementMode == .relative)
    #expect(head.applied.first?.distanceToEdge == 0.3)
}

@MainActor
@Test func realLoaderFromDiskFeedsTheApplyAndHonorsProvider() throws {
    // End-to-end: a real JSON file on disk → the real `LocalConfigService` loader → the head sink and
    // the provider resolution (no fake loader). Proves the actual load+apply chain, not just the seam.
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("launchconfig-\(UUID().uuidString)", isDirectory: true)
    let url = dir.appendingPathComponent("local-config.json")
    let saved = LocalConfig(
        sttProvider: .assemblyai,
        headPointer: HeadPointerConfig(movementMode: .edge, speed: 7, distanceToEdge: 0.2))
    try LocalConfigService.update(saved, at: url)   // write a real config file to disk
    defer { try? FileManager.default.removeItem(at: dir) }

    let head = FakeHeadConfigSink()
    let applied = LaunchConfig.applyAtLaunch(head: head, load: { try LocalConfigService.load(at: url) })

    #expect(applied.config == saved)
    #expect(head.applied.first?.speed == 7)          // the on-disk speed reached the service
    #expect(head.applied.first?.movementMode == .edge)
    #expect(applied.speech == .onDeviceDegraded)     // the on-disk provider (assemblyai) was honored/surfaced
}

@Test func speechProviderResolutionMapsBothProvidersAndSurfacesTheDegrade() {
    #expect(SpeechProviderResolution.resolve(.native) == .onDevice)
    #expect(SpeechProviderResolution.resolve(.assemblyai) == .onDeviceDegraded)
    // The degraded path must be SURFACED (not silently ignored): its log summary names the gap.
    #expect(SpeechProviderResolution.onDeviceDegraded.logSummary.contains("not yet ported"))
    #expect(SpeechProviderResolution.onDevice.logSummary.contains("native"))
}
