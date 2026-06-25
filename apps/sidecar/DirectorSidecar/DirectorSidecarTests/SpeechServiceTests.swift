//
//  SpeechServiceTests.swift
//  DirectorSidecarTests
//
//  Drift guards for the Swift STT service port of src-tauri/src/commands/stt.rs
//  and the SpeechAnalyzer engine gate from native_permissions.m.
//

import Foundation
import Testing
@testable import DirectorSidecar

@Test func buildsWorkerTokenRequestAndAuthHeader() throws {
    let shape = try SpeechService.buildWorkerTokenRequest(
        workerURL: "https://token.handsoff.test/v1/realtime-token",
        appToken: " app-secret ",
        expiresInSeconds: 60
    )

    #expect(shape.url.absoluteString == "https://token.handsoff.test/v1/realtime-token?expires_in_seconds=60")
    #expect(shape.authorization == "Bearer app-secret")
}

@Test func tokenRequestUsesWorkerBoundaryOnly() throws {
    let request = try SpeechService.tokenRequest(
        workerURL: "https://token.handsoff.test/v1/realtime-token",
        appToken: "app-secret",
        requestedExpiresInSeconds: 10_000
    )

    #expect(request.url?.host == "token.handsoff.test")
    #expect(request.url?.query == "expires_in_seconds=600")
    #expect(request.httpMethod == "GET")
    #expect(request.httpBody == nil)
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer app-secret")
}

@Test func rejectsUnsafeWorkerTokenUrls() {
    #expect(throws: SpeechService.Failure.invalidConfiguration("invalid-configuration: STT token Worker URL must use https")) {
        _ = try SpeechService.buildWorkerTokenRequest(
            workerURL: "http://token.handsoff.test/v1/realtime-token",
            appToken: "app-secret",
            expiresInSeconds: 60
        )
    }

    #expect(throws: SpeechService.Failure.invalidConfiguration("invalid-configuration: STT token Worker URL must not include query or fragment")) {
        _ = try SpeechService.buildWorkerTokenRequest(
            workerURL: "https://token.handsoff.test/v1/realtime-token?debug=true",
            appToken: "app-secret",
            expiresInSeconds: 60
        )
    }
}

@Test func rejectsEmptyAppAuthToken() {
    #expect(throws: SpeechService.Failure.missingCredentials("missing-credentials: HANDSOFF_STT_APP_AUTH_TOKEN is empty")) {
        _ = try SpeechService.buildWorkerTokenRequest(
            workerURL: "https://token.handsoff.test/v1/realtime-token",
            appToken: " ",
            expiresInSeconds: 60
        )
    }
}

@Test func validatesWorkerTokenResponse() throws {
    let token = try SpeechService.validateWorkerTokenResponse(
        SpeechService.TokenWorkerResponse(token: "stream-token", expiresInSeconds: 60)
    )

    #expect(token == SpeechService.StreamingToken(token: "stream-token", expiresInSeconds: 60))
}

@Test func rejectsInvalidWorkerTokenResponse() {
    #expect(throws: SpeechService.Failure.providerUnavailable("provider-unavailable: Worker returned an empty token")) {
        _ = try SpeechService.validateWorkerTokenResponse(
            SpeechService.TokenWorkerResponse(token: " ", expiresInSeconds: 60)
        )
    }

    #expect(throws: SpeechService.Failure.providerUnavailable("provider-unavailable: Worker returned an invalid token expiry")) {
        _ = try SpeechService.validateWorkerTokenResponse(
            SpeechService.TokenWorkerResponse(token: "stream-token", expiresInSeconds: 0)
        )
    }
}

@Test func clampsRequestedExpiryToAssemblyAiWindow() {
    #expect(SpeechService.clampExpires(nil) == 60)
    #expect(SpeechService.clampExpires(0) == 1)
    #expect(SpeechService.clampExpires(10_000) == 600)
}

@Test func selectsSpeechAnalyzerOnlyWhenRuntimeAndSdkSupportIt() {
    #expect(SpeechService.selectedOnDeviceEngine(macOSMajorVersion: 25, speechAnalyzerCompiled: true) == .sfSpeechRecognizer)
    #expect(SpeechService.selectedOnDeviceEngine(macOSMajorVersion: 26, speechAnalyzerCompiled: true) == .speechAnalyzer)
    #expect(SpeechService.selectedOnDeviceEngine(macOSMajorVersion: 26, speechAnalyzerCompiled: false) == .sfSpeechRecognizer)
}

@Test func mapsNativePermissionStatusesToContractStates() {
    #expect(SpeechService.permissionState(nativeStatus: 0) == .notDetermined)
    #expect(SpeechService.permissionState(nativeStatus: 1) == .denied)
    #expect(SpeechService.permissionState(nativeStatus: 2) == .denied)
    #expect(SpeechService.permissionState(nativeStatus: 3) == .granted)
    #expect(SpeechService.permissionState(nativeStatus: -1) == .unknown)
}
