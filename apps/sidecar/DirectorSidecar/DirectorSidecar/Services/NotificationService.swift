//
//  NotificationService.swift
//  DirectorSidecar
//
//  Local user notifications for the supervision model: tell the user when an agent needs their
//  go-ahead or has finished, so they can stay out of the app and come back only when it matters.
//  No entitlement needed — UNUserNotifications is a runtime authorization. Fed every bridge frame
//  through the app's fan-out; it derives the two signals worth interrupting for and dedups them.
//

import Foundation
import UserNotifications

@MainActor
final class NotificationService: NSObject, UNUserNotificationCenterDelegate {
    /// id → human title, learned from `sessions` frames so a `runResult` can name the agent.
    private var titles: [String: String] = [:]
    private var notifiedDone = Set<String>()      // sessionId:status — one alert per terminal result
    private var notifiedApproval = Set<String>()  // intent id — one alert per approval ask

    override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    /// Ask once (no-op if already decided). Called when the user enters the app, not at launch.
    func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func apply(_ frame: BridgeFrame) {
        guard AppPreferences.notificationsEnabled else { return }
        switch frame {
        case let .sessions(payload):
            for session in payload.sessions { titles[session.id] = session.title ?? "Your agent" }

        case let .runResult(result):
            guard let id = result.sessionId else { return }
            let key = id + ":" + result.status.rawValue
            guard notifiedDone.insert(key).inserted else { return }
            let who = titles[id] ?? "Your agent"
            switch result.status {
            case .succeeded:
                post(title: "Task complete", body: "\(who) finished.")
            case .failed, .rejected, .blocked:
                post(title: "Task stopped", body: "\(who) didn't finish — open Director to review.")
            case .queued, .running:
                break
            }

        case let .intent(intent):
            let needsYou = intent.requiresApproval
                || intent.riskLevel == .mutating || intent.riskLevel == .destructiveExternal
            guard needsYou, let id = intent.id, notifiedApproval.insert(id).inserted else { return }
            post(title: "Needs your go-ahead", body: intent.summary ?? "An action is waiting for your approval.")

        default:
            break
        }
    }

    private func post(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }

    /// Show the banner even while Director itself is frontmost (the user may be on the dashboard).
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
