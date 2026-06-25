import Foundation
import Network

extension BridgeServer {
    func upgradeWebSocket(connection: NWConnection, headers: [String: String], path: String) {
        let clientKey = connectionKey(connection)
        if authLimiter.isBlocked(key: clientKey) {
            BridgeHTTP.respondJSON(connection, status: 429, value: ActionResponse(success: false, message: "Too many failed auth attempts"))
            return
        }
        guard path == "/ws", authorized(headers: headers, clientKey: clientKey) else {
            authLimiter.recordFailure(key: clientKey)
            BridgeHTTP.respondJSON(connection, status: 401, value: ActionResponse(success: false, message: "Unauthorized"))
            return
        }
        authLimiter.reset(key: clientKey)
        guard let key = headers["sec-websocket-key"] else {
            connection.cancel()
            return
        }
        let accept = BridgeWebSocket.accept(key: key)
        let response = """
        HTTP/1.1 101 Switching Protocols\r
        Upgrade: websocket\r
        Connection: Upgrade\r
        Sec-WebSocket-Accept: \(accept)\r
        \r

        """
        connection.send(content: response.data(using: .utf8), completion: .contentProcessed { [weak self] _ in
            guard let self else { return }
            websockets[ObjectIdentifier(connection)] = connection
            let status = automation.detectSessionStatus()
            if let data = try? JSONEncoder().encode(WebSocketEvent(type: "status_changed", status: status)),
               let json = String(data: data, encoding: .utf8) {
                connection.send(content: BridgeWebSocket.textFrame(json), completion: .contentProcessed { _ in })
            }
            listenWebSocket(connection)
        })
    }

    func listenWebSocket(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 2, maximumLength: 4096) { [weak self] _, _, isComplete, error in
            if isComplete || error != nil {
                self?.websockets.removeValue(forKey: ObjectIdentifier(connection))
                connection.cancel()
                return
            }
            self?.listenWebSocket(connection)
        }
    }
}
