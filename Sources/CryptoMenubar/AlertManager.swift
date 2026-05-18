import Foundation
import UserNotifications

// Tiny wrapper around UNUserNotificationCenter. Requests permission once,
// then exposes a single `notify(...)` call used when a token crosses a threshold.

enum AlertDirection {
    case high
    case low

    var verb: String { self == .high ? "above" : "below" }
    var symbol: String { self == .high ? "↑" : "↓" }
}

@MainActor
final class AlertManager {
    private let center = UNUserNotificationCenter.current()

    /// Ask the user for notification permission if we haven't already.
    /// Idempotent — macOS only prompts the first time; subsequent calls are no-ops.
    func requestPermissionIfNeeded() async -> Bool {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined:
            return (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        case .authorized, .provisional:
            return true
        case .denied:
            return false
        @unknown default:
            return false
        }
    }

    func isAuthorized() async -> Bool {
        let settings = await center.notificationSettings()
        return [.authorized, .provisional].contains(settings.authorizationStatus)
    }

    func notify(
        token: Token,
        currentPrice: Double,
        direction: AlertDirection,
        threshold: Double
    ) {
        let content = UNMutableNotificationContent()
        content.title = "\(direction.symbol) \(token.symbol) \(direction.verb) \(formatPrice(threshold))"
        content.body = "Current: \(formatPrice(currentPrice)) — \(token.name)"
        content.sound = .default
        content.interruptionLevel = .active

        let req = UNNotificationRequest(
            identifier: "alert-\(token.id)-\(direction.verb)-\(Date().timeIntervalSince1970)",
            content: content,
            trigger: nil // deliver immediately
        )
        center.add(req) { _ in }
    }
}
