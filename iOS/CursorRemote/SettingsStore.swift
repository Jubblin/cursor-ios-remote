import Foundation
import SwiftUI

@MainActor
final class SettingsStore: ObservableObject {
    @Published var settings: BridgeSettings {
        didSet { save() }
    }

    private let key = "bridge_settings"

    private struct PersistedSettings: Codable {
        var hostname: String
        var port: Int
        var useHTTPS: Bool
        var selectedAgentId: String?
    }

    init() {
        let keychainToken = KeychainStore.loadToken() ?? ""
        if let data = UserDefaults.standard.data(forKey: key) {
            if let persisted = try? JSONDecoder().decode(PersistedSettings.self, from: data) {
                settings = BridgeSettings(
                    hostname: persisted.hostname,
                    port: persisted.port,
                    token: keychainToken,
                    useHTTPS: persisted.useHTTPS,
                    selectedAgentId: persisted.selectedAgentId
                )
            } else if let legacy = try? JSONDecoder().decode(BridgeSettings.self, from: data) {
                let token = legacy.token.isEmpty ? keychainToken : legacy.token
                if !legacy.token.isEmpty {
                    KeychainStore.saveToken(legacy.token)
                }
                settings = BridgeSettings(
                    hostname: legacy.hostname,
                    port: legacy.port,
                    token: token,
                    useHTTPS: legacy.useHTTPS,
                    selectedAgentId: legacy.selectedAgentId
                )
                save()
            } else {
                settings = BridgeSettings(
                    hostname: "",
                    port: 8742,
                    token: keychainToken,
                    useHTTPS: false,
                    selectedAgentId: nil
                )
            }
        } else {
            settings = BridgeSettings(
                hostname: "",
                port: 8742,
                token: keychainToken,
                useHTTPS: false,
                selectedAgentId: nil
            )
        }
    }

    func importPairingJSON(_ json: String) -> Bool {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hostname = object["hostname"] as? String,
              let token = object["token"] as? String,
              !hostname.isEmpty,
              !token.isEmpty else { return false }
        let port = object["port"] as? Int ?? 8742
        let useHTTPS = (object["useHTTPS"] as? Bool) ?? settings.useHTTPS
        settings = BridgeSettings(
            hostname: hostname,
            port: port,
            token: token,
            useHTTPS: useHTTPS,
            selectedAgentId: settings.selectedAgentId
        )
        return true
    }

    private func save() {
        if settings.token.isEmpty {
            KeychainStore.deleteToken()
        } else {
            KeychainStore.saveToken(settings.token)
        }
        let persisted = PersistedSettings(
            hostname: settings.hostname,
            port: settings.port,
            useHTTPS: settings.useHTTPS,
            selectedAgentId: settings.selectedAgentId
        )
        if let data = try? JSONEncoder().encode(persisted) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
