import SwiftUI
import UserNotifications

@main
struct CursorRemoteApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var settings = SettingsStore()
    @StateObject private var notifications = NotificationManager()
    @StateObject private var client: BridgeClient

    init() {
        let settings = SettingsStore()
        _settings = StateObject(wrappedValue: settings)
        _client = StateObject(wrappedValue: BridgeClient(settings: settings.settings))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(settings)
                .environmentObject(client)
                .environmentObject(notifications)
                .onAppear {
                    UNUserNotificationCenter.current().delegate = notifications
                    client.updateSettings(settings.settings)
                    client.connect()
                    Task { await notifications.requestPermission() }
                    NotificationCenter.default.addObserver(
                        forName: .didRegisterForRemoteNotifications,
                        object: nil,
                        queue: .main
                    ) { note in
                        guard let token = note.userInfo?["token"] as? Data else { return }
                        notifications.handleDeviceToken(token)
                    }
                }
                .onChange(of: settings.settings) { _, newValue in
                    client.updateSettings(newValue)
                    client.connect()
                }
                .onChange(of: notifications.deviceToken) { _, token in
                    guard let token else { return }
                    Task { await client.registerDevice(token: token) }
                }
        }
    }
}
