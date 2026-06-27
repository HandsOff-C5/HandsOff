//
//  AppPreferences.swift
//  DirectorSidecar
//
//  Small UserDefaults-backed UI preferences for the Flow-to-First-Run onboarding — the native
//  parallel to the web mock's `localStorage` (`director.onboardingDone`, `director.listenEdge`).
//  Deliberately kept OUT of the engine `LocalConfig` (sttProvider / headPointer): those are
//  contract-shaped settings the loop consumes, and adding UI chrome to that Codable risks a
//  recover-to-default wipe on upgrade. UI prefs belong in UserDefaults — standard macOS practice.
//

import Foundation

/// Which screen edge the rail / listening HUD anchors to. Maps to `RailController.Edge`; `right`
/// (trailing) is the product default.
enum RailEdge: String, Sendable, Equatable, CaseIterable {
    case left
    case right

    var controllerEdge: RailController.Edge { self == .left ? .leading : .trailing }
}

/// Persisted onboarding + UI-chrome preferences. Thin static accessors over `UserDefaults.standard`
/// so call sites read like `AppPreferences.railEdge`.
enum AppPreferences {
    private static let onboardingCompletedKey = "director.onboardingCompleted"
    private static let railEdgeKey = "director.railEdge"
    private static let launchAtLoginKey = "director.launchAtLogin"
    private static let notificationsEnabledKey = "director.notificationsEnabled"

    private static var defaults: UserDefaults { .standard }

    /// Default-ON booleans: UserDefaults.bool returns false when unset, so read the object first and
    /// fall back to `true` when the key has never been written.
    private static func boolDefaultingTrue(_ key: String) -> Bool {
        defaults.object(forKey: key) == nil ? true : defaults.bool(forKey: key)
    }

    /// Whether the user has finished the onboarding at least once.
    static var onboardingCompleted: Bool {
        get { defaults.bool(forKey: onboardingCompletedKey) }
        set { defaults.set(newValue, forKey: onboardingCompletedKey) }
    }

    /// The saved rail edge; defaults to `.right` when unset or unrecognized.
    static var railEdge: RailEdge {
        get { defaults.string(forKey: railEdgeKey).flatMap(RailEdge.init(rawValue:)) ?? .right }
        set { defaults.set(newValue.rawValue, forKey: railEdgeKey) }
    }

    /// Launch Director at login — ON by default (it's a menu-bar resident).
    static var launchAtLogin: Bool {
        get { boolDefaultingTrue(launchAtLoginKey) }
        set { defaults.set(newValue, forKey: launchAtLoginKey) }
    }

    /// Local notifications when an agent needs you / finishes — ON by default.
    static var notificationsEnabled: Bool {
        get { boolDefaultingTrue(notificationsEnabledKey) }
        set { defaults.set(newValue, forKey: notificationsEnabledKey) }
    }
}

/// Whether the onboarding window should appear at launch.
enum OnboardingGate {
    /// TESTING: force the onboarding window on every relaunch, regardless of `onboardingCompleted`,
    /// so the journey can be iterated on without resetting state. Flip to `false` to restore normal
    /// "show only until completed once" behavior — no other change needed.
    static let alwaysShow = true

    static var shouldShowAtLaunch: Bool {
        alwaysShow || !AppPreferences.onboardingCompleted
    }

    /// Live latch: true while onboarding is the active first-run surface (from launch until the user
    /// finishes or it redirects to Home). Gates Home so a window macOS *restores* at launch can't show
    /// behind onboarding, and so entering-the-app side effects (the fn capture tap) don't fire early.
    /// Only ever touched on the main thread (App.init, the app-delegate callbacks, view actions), so
    /// `nonisolated(unsafe)` is accurate — and it lets the non-MainActor delegate methods read it
    /// without an isolation error on the CI toolchain (which doesn't apply default MainActor isolation
    /// the way the local Xcode 26 SDK does).
    nonisolated(unsafe) static var isPresenting = false
}
