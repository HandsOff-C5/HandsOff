//
//  LoginItemService.swift
//  DirectorSidecar
//
//  "Launch at login" via SMAppService (macOS 13+) — Director is a menu-bar resident, so it's ON by
//  default. The user can flip it in Settings. No entitlement needed: the main app registers itself.
//

import Foundation
import ServiceManagement

@MainActor
enum LoginItemService {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    /// Register/unregister the app as a login item. Idempotent; returns false (and stays quiet) if the
    /// system rejects it — never throws into the UI.
    @discardableResult
    static func setEnabled(_ on: Bool) -> Bool {
        let service = SMAppService.mainApp
        do {
            if on, service.status != .enabled {
                try service.register()
            } else if !on, service.status == .enabled {
                try service.unregister()
            }
            return true
        } catch {
            return false
        }
    }

    /// Default-ON: reflect the persisted preference into the system login item (registers on first run
    /// when the user hasn't opted out).
    static func syncToPreference() {
        setEnabled(AppPreferences.launchAtLogin)
    }
}
