//
//  ReadinessServiceTests.swift
//  DirectorSidecarTests
//
//  The native readiness payload builder, ported from `readiness.rs::readiness_payload()` and
//  pinned against the contract `CAPABILITY_IDS` (packages/contracts/src/readiness.ts): the six
//  capabilities in a fixed order, `cua` is the lone `daemon` (always `unknown` in this lane),
//  and each permission state surfaces as its contract `state` string.
//

import Foundation
import Testing
@testable import DirectorSidecar

@Test func readinessPayloadListsSixCapabilitiesInContractOrder() {
    let payload = ReadinessService.payload(
        camera: .granted,
        microphone: .denied,
        speechRecognition: .notDetermined,
        accessibility: .granted,
        screenRecording: .restricted
    )
    #expect(payload.capabilities.map(\.id) == [
        "camera", "microphone", "speech-recognition", "cua", "accessibility", "screen-recording",
    ])
}

@Test func readinessPayloadMapsPermissionStatesToContractStrings() {
    let payload = ReadinessService.payload(
        camera: .granted,
        microphone: .denied,
        speechRecognition: .notDetermined,
        accessibility: .restricted,
        screenRecording: .unknown
    )
    let byID = Dictionary(uniqueKeysWithValues: payload.capabilities.map { ($0.id, $0) })
    #expect(byID["camera"]?.state == "granted")
    #expect(byID["microphone"]?.state == "denied")
    #expect(byID["speech-recognition"]?.state == "not-determined")
    #expect(byID["accessibility"]?.state == "restricted")
    #expect(byID["screen-recording"]?.state == "unknown")
}

@Test func cuaIsTheOnlyDaemonCapabilityAndStaysUnknown() {
    let payload = ReadinessService.payload(
        camera: .granted, microphone: .granted, speechRecognition: .granted,
        accessibility: .granted, screenRecording: .granted
    )
    let daemons = payload.capabilities.filter { $0.kind == "daemon" }
    #expect(daemons.map(\.id) == ["cua"])
    #expect(daemons.first?.state == "unknown")
    // Every other capability is a permission.
    #expect(payload.capabilities.filter { $0.kind == "permission" }.count == 5)
}

@Test func readinessPayloadEncodesToTheBridgeWireShape() throws {
    let payload = ReadinessService.payload(
        camera: .granted, microphone: .granted, speechRecognition: .granted,
        accessibility: .denied, screenRecording: .denied
    )
    // Round-trips through the same Codable wire types the bridge readiness path uses.
    let data = try JSONEncoder().encode(payload)
    let decoded = try JSONDecoder().decode(ReadinessPayload.self, from: data)
    #expect(decoded.capabilities.count == 6)
    #expect(decoded.capabilities.map(\.id) == payload.capabilities.map(\.id))
}
