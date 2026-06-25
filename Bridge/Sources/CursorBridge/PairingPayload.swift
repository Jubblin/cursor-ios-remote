import Foundation

enum PairingPayload {
    static func json(hostname: String, port: Int, token: String) -> String {
        let payload: [String: Any] = [
            "hostname": hostname,
            "port": port,
            "token": token,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let string = String(data: data, encoding: .utf8) else {
            return "{\"hostname\":\"\(hostname)\",\"port\":\(port),\"token\":\"\(token)\"}"
        }
        return string
    }

    static func current(hostname: String?, port: Int, token: String) -> String {
        json(
            hostname: hostname ?? "your-mac.tailnet-name.ts.net",
            port: port,
            token: token
        )
    }
}
