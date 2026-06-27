//
//  DashboardSettingsView.swift
//  DirectorSidecar
//
//  The Settings tab (pinned bottom-left). A native grouped Form — first pass with appearance + about.
//  Real preferences (listen edge, mic, languages, shortcuts) wire up with the onboarding step.
//

import SwiftUI
import UserNotifications

struct DashboardSettingsView: View {
    @State private var launchAtLogin = AppPreferences.launchAtLogin
    @State private var notificationsOn = AppPreferences.notificationsEnabled

    var body: some View {
        Form {
            Section("Appearance") {
                LabeledContent("Theme", value: "Follows System")
            }
            Section("Startup & alerts") {
                Toggle("Launch Director at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        AppPreferences.launchAtLogin = on
                        LoginItemService.setEnabled(on)
                    }
                Toggle("Notify me when an agent needs me or finishes", isOn: $notificationsOn)
                    .onChange(of: notificationsOn) { _, on in
                        AppPreferences.notificationsEnabled = on
                        // Turning it back on may need a fresh authorization (no-op if already decided).
                        if on {
                            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
                        }
                    }
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
