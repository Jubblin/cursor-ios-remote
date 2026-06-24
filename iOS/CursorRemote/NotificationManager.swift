import Foundation
import UserNotifications
import UIKit

@MainActor
final class NotificationManager: NSObject, ObservableObject {
    @Published var deviceToken: String?
    @Published var permissionGranted = false

    func requestPermission() async {
        let center = UNUserNotificationCenter.current()
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            permissionGranted = granted
            if granted {
                UIApplication.shared.registerForRemoteNotifications()
            }
        } catch {
            permissionGranted = false
        }
    }

    func handleDeviceToken(_ tokenData: Data) {
        let token = tokenData.map { String(format: "%02x", $0) }.joined()
        deviceToken = token
    }
}

extension NotificationManager: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        // Deep link handled by app opening to session view
    }
}
