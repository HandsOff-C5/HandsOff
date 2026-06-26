//
//  LocalConfigServiceTests.swift
//  DirectorSidecarTests
//
//  Local config load/update/reset coverage, ported 1:1 from the Rust `storage.rs` tests:
//  a missing file recovers to (and writes) the default; update persists a custom config;
//  reset restores defaults without touching sibling files; an unknown provider, an unknown
//  movement mode, an out-of-range speed, or an old config missing `headPointer` all recover
//  to default on load; update REJECTS out-of-range settings. Each test uses a unique temp path.
//

import Foundation
import Testing
@testable import DirectorSidecar

private func tempConfigURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("trackE-config-tests", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
        .appendingPathComponent("local-config.json", isDirectory: false)
}

private func writeRaw(_ json: String, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(json.utf8).write(to: url)
}

@Test func contractDefaultUsesSpeedFive() {
    // The persisted default is the CONTRACT default (speed 5), NOT the head-track runtime
    // default (HeadPointerConfig.default == speed 8).
    #expect(LocalConfig.default.sttProvider == .native)
    #expect(LocalConfig.default.headPointer.movementMode == .edge)
    #expect(LocalConfig.default.headPointer.speed == 5)
    #expect(LocalConfig.default.headPointer.distanceToEdge == 0.12)
    #expect(HeadPointerConfig.default.speed == 8) // guards the divergence we deliberately keep
}

@Test func loadCreatesDefaultConfigWhenMissing() throws {
    let url = tempConfigURL()
    let config = try LocalConfigService.load(at: url)
    #expect(config == .default)
    // The default was written to disk and parses back.
    let stored = try JSONDecoder().decode(LocalConfig.self, from: try Data(contentsOf: url))
    #expect(stored == .default)
}

@Test func updatePersistsCustomConfig() throws {
    let url = tempConfigURL()
    let updated = LocalConfig(
        sttProvider: .assemblyai,
        headPointer: HeadPointerConfig(movementMode: .relative, speed: 8, distanceToEdge: 0.25)
    )
    _ = try LocalConfigService.update(updated, at: url)
    #expect(try LocalConfigService.load(at: url) == updated)
}

@Test func resetRestoresDefaultsWithoutTouchingSiblingFiles() throws {
    let url = tempConfigURL()
    let sibling = url.deletingLastPathComponent().appendingPathComponent("unrelated-preferences.json")
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("keep me".utf8).write(to: sibling)

    let reset = try LocalConfigService.reset(at: url)
    #expect(reset == .default)
    #expect(try LocalConfigService.load(at: url) == .default)
    #expect(try String(contentsOf: sibling, encoding: .utf8) == "keep me")
}

@Test func invalidProviderRecoversToDefaults() throws {
    let url = tempConfigURL()
    try writeRaw(#"{"sttProvider":"ambient","headPointer":{"movementMode":"edge","speed":5,"distanceToEdge":0.12}}"#, to: url)
    let recovered = try LocalConfigService.load(at: url)
    #expect(recovered == .default)
    // The recovered default was written back.
    let stored = try JSONDecoder().decode(LocalConfig.self, from: try Data(contentsOf: url))
    #expect(stored == .default)
}

@Test func invalidHeadPointerModeRecoversToDefaults() throws {
    let url = tempConfigURL()
    try writeRaw(#"{"sttProvider":"native","headPointer":{"movementMode":"orbit","speed":5,"distanceToEdge":0.12}}"#, to: url)
    #expect(try LocalConfigService.load(at: url) == .default)
}

@Test func invalidHeadPointerRangesRecoverToDefaults() throws {
    let url = tempConfigURL()
    // speed 31 parses fine but fails the range check → recover to default on load.
    try writeRaw(#"{"sttProvider":"native","headPointer":{"movementMode":"edge","speed":31,"distanceToEdge":0.12}}"#, to: url)
    #expect(try LocalConfigService.load(at: url) == .default)
}

@Test func updateRejectsInvalidHeadPointerRanges() {
    let url = tempConfigURL()
    let invalid = LocalConfig(
        sttProvider: .native,
        headPointer: HeadPointerConfig(movementMode: .edge, speed: 0, distanceToEdge: 0.12)
    )
    #expect(throws: LocalConfigError.invalidSettings) {
        try LocalConfigService.update(invalid, at: url)
    }
}

@Test func oldConfigMissingHeadPointerRecoversToDefaults() throws {
    let url = tempConfigURL()
    try writeRaw(#"{"sttProvider":"assemblyai"}"#, to: url)
    let recovered = try LocalConfigService.load(at: url)
    #expect(recovered == .default)
    let stored = try JSONDecoder().decode(LocalConfig.self, from: try Data(contentsOf: url))
    #expect(stored == .default)
}
