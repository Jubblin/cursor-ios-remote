import CryptoKit
import Foundation
import Network

enum BridgeHTTP {
    static func queryFlag(path: String, name: String) -> Bool {
        guard let query = path.split(separator: "?", maxSplits: 1).dropFirst().first else { return false }
        return query.split(separator: "&").contains { part in
            let pieces = part.split(separator: "=", maxSplits: 1).map(String.init)
            return pieces.first == name && (pieces.count < 2 || pieces[1] == "1" || pieces[1].lowercased() == "true")
        }
    }

    static func queryInt(path: String, name: String) -> Int? {
        guard let query = path.split(separator: "?", maxSplits: 1).dropFirst().first else { return nil }
        for part in query.split(separator: "&") {
            let pieces = part.split(separator: "=", maxSplits: 1).map(String.init)
            guard pieces.first == name, pieces.count == 2, let value = Int(pieces[1]) else { continue }
            return value
        }
        return nil
    }

    static func respondJSON(_ connection: NWConnection, status: Int, value: some Encodable) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(value) else {
            connection.cancel()
            return
        }
        let response = """
        HTTP/1.1 \(status) OK\r
        Content-Type: application/json\r
        Content-Length: \(data.count)\r
        Connection: close\r
        \r

        """
        var out = Data(response.utf8)
        out.append(data)
        connection.send(content: out, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}

enum BridgeWebSocket {
    static func accept(key: String) -> String {
        let magic = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
        let sha = Insecure.SHA1.hash(data: Data((key + magic).utf8))
        return Data(sha).base64EncodedString()
    }

    static func textFrame(_ text: String) -> Data {
        let payload = Data(text.utf8)
        var frame = Data()
        frame.append(0x81)
        if payload.count < 126 {
            frame.append(UInt8(payload.count))
        } else {
            frame.append(126)
            frame.append(UInt8((payload.count >> 8) & 0xFF))
            frame.append(UInt8(payload.count & 0xFF))
        }
        frame.append(payload)
        return frame
    }
}
