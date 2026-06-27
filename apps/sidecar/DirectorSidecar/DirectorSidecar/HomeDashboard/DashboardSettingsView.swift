//
//  DashboardSettingsView.swift
//  DirectorSidecar
//
//  The Settings tab (pinned bottom-left). A native grouped Form — first pass with appearance + about.
//  Real preferences (listen edge, mic, languages, shortcuts) wire up with the onboarding step.
//

import SwiftUI

struct DashboardSettingsView: View {
    var body: some View {
        Form {
            Section("Appearance") {
                LabeledContent("Theme", value: "Follows System")
            }
            Section("Activation") {
                LabeledContent("Trigger", value: "Hold fn")
                LabeledContent("Listening", value: "On-device")
            }
            Section("About") {
                LabeledContent("Version", value: appVersion)
                LabeledContent("Engine", value: "Director / HandsOff")
            }
        }
        .formStyle(.grouped)
    }

    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "0.1"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "\(short) (\(build))"
    }
}
