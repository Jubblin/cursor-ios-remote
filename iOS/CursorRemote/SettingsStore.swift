import Foundation
import SwiftUI

@MainActor
final class SettingsStore: ObservableObject {
    @Published var settings: BridgeSettings {
        didSet { save() }
    }

    private let key = "bridge_settings"

    init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let decoded = try? JSONDecoder().decode(BridgeSettings.self, from: data) {
            settings = decoded
        } else {
            settings = .default
        }
    }

    func importPairingJSON(_ json: String) {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hostname = object["hostname"] as? String,
              let token = object["token"] as? String else { return }
        let port = object["port"] as? Int ?? 8742
        settings = BridgeSettings(hostname: hostname, port: port, token: token, useHTTPS: false)
    }

    private func save() {
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
