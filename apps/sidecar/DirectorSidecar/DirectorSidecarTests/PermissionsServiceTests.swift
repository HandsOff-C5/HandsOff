//
//  PermissionsServiceTests.swift
//  DirectorSidecarTests
//
//  Pure permission-status mapping coverage, ported from the Rust `permissions.rs` /
//  `readiness.rs` tests. The load-bearing edge case: SFSpeechRecognizerAuthorizationStatus
//  and AVAuthorizationStatus DISAGREE on the meaning of 1 and 2 (swapped restricted/denied),
//  so the two mappers must stay distinct. Also pins the System Settings deep-link anchors.
//

import Testing
@testable import DirectorSidecar

@Test func mapsSpeechAuthorizationStatuses() {
    // SFSpeechRecognizerAuthorizationStatus: 0 notDetermined, 1 denied, 2 restricted, 3 authorized.
    #expect(PermissionsService.speechState(fromRawStatus: 0) == .notDetermined)
    #expect(PermissionsService.speechState(fromRawStatus: 1) == .denied)
    #expect(PermissionsService.speechState(fromRawStatus: 2) == .restricted)
    #expect(PermissionsService.speechState(fromRawStatus: 3) == .granted)
    #expect(PermissionsService.speechState(fromRawStatus: 99) == .unknown)
}

@Test func mapsAVAuthorizationStatuses() {
    // AVAuthorizationStatus: 0 notDetermined, 1 restricted, 2 denied, 3 authorized.
    #expect(PermissionsService.avState(fromRawStatus: 0) == .notDetermined)
    #expect(PermissionsService.avState(fromRawStatus: 1) == .restricted)
    #expect(PermissionsService.avState(fromRawStatus: 2) == .denied)
    #expect(PermissionsService.avState(fromRawStatus: 3) == .granted)
    #expect(PermissionsService.avState(fromRawStatus: 99) == .unknown)
}

@Test func speechAndAVMappersDisagreeOnOneAndTwo() {
    // The whole reason for two mappers: status 1 and 2 mean opposite things.
    #expect(PermissionsService.speechState(fromRawStatus: 1) == .denied)
    #expect(PermissionsService.avState(fromRawStatus: 1) == .restricted)
    #expect(PermissionsService.speechState(fromRawStatus: 2) == .restricted)
    #expect(PermissionsService.avState(fromRawStatus: 2) == .denied)
}

@Test func permissionStateRawValuesMatchContract() {
    // The `permissionStateSchema` strings (packages/contracts/src/readiness.ts).
    #expect(PermissionState.granted.rawValue == "granted")
    #expect(PermissionState.denied.rawValue == "denied")
    #expect(PermissionState.notDetermined.rawValue == "not-determined")
    #expect(PermissionState.restricted.rawValue == "restricted")
    #expect(PermissionState.unknown.rawValue == "unknown")
}

@Test func privacyPaneAnchorsMatchSystemSettings() {
    #expect(PrivacyPane.camera.settingsAnchor == "Privacy_Camera")
    #expect(PrivacyPane.microphone.settingsAnchor == "Privacy_Microphone")
    #expect(PrivacyPane.speechRecognition.settingsAnchor == "Privacy_SpeechRecognition")
    #expect(PrivacyPane.accessibility.settingsAnchor == "Privacy_Accessibility")
    #expect(PrivacyPane.screenRecording.settingsAnchor == "Privacy_ScreenCapture")
}

@Test func privacyPaneURLIsWellFormed() {
    let url = PrivacyPane.accessibility.settingsURL
    #expect(url?.absoluteString == "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
}

@Test func privacyPaneRawValuesMatchOldCommandStrings() {
    // The pane vocabulary the old `open_privacy_settings` command accepted.
    #expect(PrivacyPane.speechRecognition.rawValue == "speech-recognition")
    #expect(PrivacyPane.screenRecording.rawValue == "screen-recording")
}
