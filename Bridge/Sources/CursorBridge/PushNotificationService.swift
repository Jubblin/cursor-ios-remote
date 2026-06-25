import CryptoKit
import Foundation

final class PushNotificationService {
    private var deviceTokens: Set<String> = []
    private let lock = NSLock()

    func register(token: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if deviceTokens.contains(token) { return true }
        if deviceTokens.count >= BridgeSecurity.maxDeviceTokens { return false }
        deviceTokens.insert(token)
        return true
    }

    func sendApprovalRequest(detail: String?) async {
        let tokens: [String] = lock.withLock { Array(deviceTokens) }
        guard !tokens.isEmpty else { return }

        guard let keyPath = ProcessInfo.processInfo.environment["APNS_KEY_PATH"],
              let keyId = ProcessInfo.processInfo.environment["APNS_KEY_ID"],
              let teamId = ProcessInfo.processInfo.environment["APNS_TEAM_ID"],
              let topic = ProcessInfo.processInfo.environment["APNS_TOPIC"],
              let keyData = try? Data(contentsOf: URL(fileURLWithPath: keyPath))
        else {
            print("[APNs] Skipping push — configure APNS_KEY_PATH, APNS_KEY_ID, APNS_TEAM_ID, APNS_TOPIC")
            return
        }

        do {
            let jwt = try makeAPNSJWT(teamId: teamId, keyId: keyId, keyData: keyData)
            let payload = ApprovalPayload(
                aps: APSPayload(
                    alert: AlertPayload(
                        title: "Cursor needs approval",
                        body: detail ?? "Agent is waiting for your decision"
                    ),
                    sound: "default"
                ),
                action: "approval_required"
            )
            let body = try JSONEncoder().encode(payload)
            for token in tokens {
                try await post(deviceToken: token, topic: topic, jwt: jwt, body: body)
            }
        } catch {
            print("[APNs] Failed: \(error)")
        }
    }

    private func makeAPNSJWT(teamId: String, keyId: String, keyData: Data) throws -> String {
        let header = ["alg": "ES256", "kid": keyId]
        let now = Int(Date().timeIntervalSince1970)
        let claims: [String: Any] = ["iss": teamId, "iat": now]
        let headerData = try JSONSerialization.data(withJSONObject: header)
        let claimsData = try JSONSerialization.data(withJSONObject: claims)
        let signingInput = "\(headerData.base64URLEncoded()).\(claimsData.base64URLEncoded())"
        let key = try P256.Signing.PrivateKey(derRepresentation: parsePKCS8(keyData))
        let signature = try key.signature(for: Data(signingInput.utf8))
        let sig = signature.derRepresentation.base64URLEncoded()
        return "\(signingInput).\(sig)"
    }

    private func parsePKCS8(_ data: Data) throws -> Data {
        let pem = String(data: data, encoding: .utf8) ?? ""
        if pem.contains("BEGIN PRIVATE KEY") {
            let lines = pem.split(separator: "\n").filter { !$0.hasPrefix("-----") }
            guard let raw = Data(base64Encoded: lines.joined()) else {
                throw PushError.invalidKey
            }
            return raw
        }
        return data
    }

    private func post(deviceToken: String, topic: String, jwt: String, body: Data) async throws {
        var request = URLRequest(url: URL(string: "https://api.push.apple.com/3/device/\(deviceToken)")!)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("bearer \(jwt)", forHTTPHeaderField: "authorization")
        request.setValue(topic, forHTTPHeaderField: "apns-topic")
        request.setValue("alert", forHTTPHeaderField: "apns-push-type")
        request.setValue("10", forHTTPHeaderField: "apns-priority")
        let (_, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            print("[APNs] HTTP \(http.statusCode)")
        }
    }
}

private enum PushError: Error {
    case invalidKey
}

private struct ApprovalPayload: Codable {
    let aps: APSPayload
    let action: String
}

private struct APSPayload: Codable {
    let alert: AlertPayload
    let sound: String
}

private struct AlertPayload: Codable {
    let title: String
    let body: String
}

private extension Data {
    func base64URLEncoded() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
