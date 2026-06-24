import CryptoKit
import Foundation
import Network

final class BridgeServer {
    private let port: UInt16
    private let authToken: String
    private let automation = CursorAutomation()
    private let catalog = ConversationCatalog()
    private let pushService = PushNotificationService()
    private let startedAt = Date()
    private var listener: NWListener?
    private var websockets: [ObjectIdentifier: NWConnection] = [:]
    private var pollTimer: DispatchSourceTimer?
    private var lastStatus: SessionStatus?
    private let queue = DispatchQueue(label: "cursor.bridge.server")

    init(port: Int, authToken: String) {
        self.port = UInt16(port)
        self.authToken = authToken
    }

    func start() throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        listener?.newConnectionHandler = { [weak self] connection in
            self?.handle(connection: connection)
        }
        listener?.start(queue: queue)
        startPolling()
        print("[Bridge] Listening on 0.0.0.0:\(port)")
    }

    func stop() {
        pollTimer?.cancel()
        listener?.cancel()
        websockets.values.forEach { $0.cancel() }
        websockets.removeAll()
    }

    private func startPolling() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 2)
        timer.setEventHandler { [weak self] in
            self?.pollStatus()
        }
        timer.resume()
        pollTimer = timer
    }

    private func pollStatus() {
        let status = automation.detectSessionStatus()
        if lastStatus?.state != status.state {
            lastStatus = status
            broadcast(status)
            if status.state == .awaitingApproval {
                Task { await pushService.sendApprovalRequest(detail: status.detail) }
            }
        }
    }

    private func broadcast(_ status: SessionStatus) {
        let event = WebSocketEvent(type: "status_changed", status: status)
        guard let data = try? JSONEncoder().encode(event),
              let json = String(data: data, encoding: .utf8) else { return }
        let frame = Self.wsTextFrame(json)
        for (_, conn) in websockets {
            conn.send(content: frame, completion: .contentProcessed { _ in })
        }
    }

    private func handle(connection: NWConnection) {
        connection.start(queue: queue)
        receiveHTTP(on: connection, buffer: Data())
    }

    private func receiveHTTP(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, error in
            guard let self else { return }
            if let error {
                connection.cancel()
                print("[Bridge] Receive error: \(error)")
                return
            }
            var buffer = buffer
            if let data { buffer.append(data) }
            guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                self.receiveHTTP(on: connection, buffer: buffer)
                return
            }
            let headerData = buffer.subdata(in: 0 ..< headerEnd.lowerBound)
            let bodyData = buffer.subdata(in: headerEnd.upperBound ..< buffer.count)
            guard let headerText = String(data: headerData, encoding: .utf8) else {
                connection.cancel()
                return
            }
            let lines = headerText.split(separator: "\r\n", omittingEmptySubsequences: false)
            guard let requestLine = lines.first else {
                connection.cancel()
                return
            }
            let parts = requestLine.split(separator: " ")
            guard parts.count >= 2 else {
                connection.cancel()
                return
            }
            let method = String(parts[0])
            let path = String(parts[1])
            var headers: [String: String] = [:]
            for line in lines.dropFirst() {
                if let idx = line.firstIndex(of: ":") {
                    let key = String(line[..<idx]).trimmingCharacters(in: .whitespaces).lowercased()
                    let value = String(line[line.index(after: idx)...]).trimmingCharacters(in: .whitespaces)
                    headers[key] = value
                }
            }

            if headers["upgrade"]?.lowercased() == "websocket" {
                self.upgradeWebSocket(connection: connection, headers: headers, path: path)
                return
            }

            let contentLength = Int(headers["content-length"] ?? "0") ?? 0
            let body = bodyData
            if body.count < contentLength {
                self.readRemainingBody(
                    connection: connection,
                    needed: contentLength - body.count,
                    existing: body,
                    method: method,
                    path: path,
                    headers: headers
                )
                return
            }

            self.route(
                connection: connection,
                method: method,
                path: path,
                headers: headers,
                body: body
            )
        }
    }

    private func readRemainingBody(
        connection: NWConnection,
        needed: Int,
        existing: Data,
        method: String,
        path: String,
        headers: [String: String]
    ) {
        connection.receive(minimumIncompleteLength: needed, maximumLength: needed) { [weak self] data, _, _, _ in
            guard let self else { return }
            var body = existing
            if let data { body.append(data) }
            self.route(connection: connection, method: method, path: path, headers: headers, body: body)
        }
    }

    private func route(
        connection: NWConnection,
        method: String,
        path: String,
        headers: [String: String],
        body: Data
    ) {
        if path == "/health" {
            let health = BridgeHealth(
                ok: true,
                version: "1.0.0",
                uptimeSeconds: Int(Date().timeIntervalSince(startedAt))
            )
            respondJSON(connection, status: 200, value: health)
            return
        }

        if !authorized(headers: headers) {
            respondJSON(connection, status: 401, value: ActionResponse(success: false, message: "Unauthorized"))
            return
        }

        let pathOnly = path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? path

        switch (method, pathOnly) {
        case ("GET", "/pairing"):
            respondJSON(connection, status: 200, value: PairingInfo(
                token: authToken,
                port: Int(port),
                hostname: Hostname.local() ?? "localhost"
            ))
        case ("GET", "/agents"):
            respondJSON(connection, status: 200, value: AgentListResponse(
                agents: catalog.listAgentConversations()
            ))
        case ("GET", "/projects"):
            let includeArchived = queryFlag(path: path, name: "include_archived")
            respondJSON(connection, status: 200, value: ProjectListResponse(
                projects: catalog.listProjects(includeArchived: includeArchived)
            ))
        case ("GET", let p) where p.hasPrefix("/projects/") && p.hasSuffix("/conversations"):
            let parts = p.split(separator: "/").map(String.init)
            guard parts.count == 3 else {
                respondJSON(connection, status: 400, value: ActionResponse(success: false, message: "Invalid path"))
                return
            }
            let projectId = parts[1]
            let includeArchived = queryFlag(path: path, name: "include_archived")
            if let list = catalog.listConversations(projectId: projectId, includeArchived: includeArchived) {
                respondJSON(connection, status: 200, value: list)
            } else {
                respondJSON(connection, status: 404, value: ActionResponse(success: false, message: "Project not found"))
            }
        case ("GET", "/session/status"):
            respondJSON(connection, status: 200, value: automation.detectSessionStatus())
        case ("POST", "/session/prompt"):
            if let req = try? JSONDecoder().decode(PromptRequest.self, from: body) {
                respondJSON(connection, status: 200, value: automation.sendPrompt(req.text))
            } else {
                respondJSON(connection, status: 400, value: ActionResponse(success: false, message: "Invalid body"))
            }
        case ("POST", "/session/approve"):
            let result = automation.approve()
            respondJSON(connection, status: 200, value: result)
        case ("POST", "/session/reject"):
            let result = automation.reject()
            respondJSON(connection, status: 200, value: result)
        case ("POST", "/agents/select"):
            if let req = try? JSONDecoder().decode(SelectAgentRequest.self, from: body),
               let agent = catalog.agent(id: req.agentId),
               let workspacePath = agent.workspacePath {
                let result = automation.selectConversation(
                    workspacePath: workspacePath,
                    conversationName: agent.name
                )
                respondJSON(connection, status: 200, value: result)
            } else {
                respondJSON(connection, status: 400, value: ActionResponse(
                    success: false,
                    message: "Agent not found or workspace unavailable"
                ))
            }
        case ("POST", "/conversations/select"):
            if let req = try? JSONDecoder().decode(SelectConversationRequest.self, from: body),
               let conversation = catalog.conversation(projectId: req.projectId, conversationId: req.conversationId),
               let workspacePath = catalog.projectPath(projectId: req.projectId) {
                let result = automation.selectConversation(
                    workspacePath: workspacePath,
                    conversationName: conversation.name
                )
                respondJSON(connection, status: 200, value: result)
            } else {
                respondJSON(connection, status: 400, value: ActionResponse(success: false, message: "Invalid project or conversation"))
            }
        case ("POST", "/devices/register"):
            if let req = try? JSONDecoder().decode(DeviceRegistration.self, from: body) {
                pushService.register(token: req.deviceToken)
                respondJSON(connection, status: 200, value: ActionResponse(success: true, message: "Registered"))
            } else {
                respondJSON(connection, status: 400, value: ActionResponse(success: false, message: "Invalid body"))
            }
        default:
            respondJSON(connection, status: 404, value: ActionResponse(success: false, message: "Not found"))
        }
    }

    private func authorized(headers: [String: String]) -> Bool {
        guard let auth = headers["authorization"] else { return false }
        return auth == "Bearer \(authToken)"
    }

    private func queryFlag(path: String, name: String) -> Bool {
        guard let query = path.split(separator: "?", maxSplits: 1).dropFirst().first else { return false }
        return query.split(separator: "&").contains { part in
            let pieces = part.split(separator: "=", maxSplits: 1).map(String.init)
            return pieces.first == name && (pieces.count < 2 || pieces[1] == "1" || pieces[1].lowercased() == "true")
        }
    }

    private func upgradeWebSocket(connection: NWConnection, headers: [String: String], path: String) {
        guard path == "/ws", authorized(headers: headers) else {
            respondJSON(connection, status: 401, value: ActionResponse(success: false, message: "Unauthorized"))
            return
        }
        guard let key = headers["sec-websocket-key"] else {
            connection.cancel()
            return
        }
        let accept = Self.websocketAccept(key: key)
        let response = """
        HTTP/1.1 101 Switching Protocols\r
        Upgrade: websocket\r
        Connection: Upgrade\r
        Sec-WebSocket-Accept: \(accept)\r
        \r

        """
        connection.send(content: response.data(using: .utf8), completion: .contentProcessed { [weak self] _ in
            guard let self else { return }
            self.websockets[ObjectIdentifier(connection)] = connection
            let status = self.automation.detectSessionStatus()
            if let data = try? JSONEncoder().encode(WebSocketEvent(type: "status_changed", status: status)),
               let json = String(data: data, encoding: .utf8) {
                connection.send(content: Self.wsTextFrame(json), completion: .contentProcessed { _ in })
            }
            self.listenWebSocket(connection)
        })
    }

    private func listenWebSocket(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 2, maximumLength: 4096) { [weak self] _, _, isComplete, error in
            if isComplete || error != nil {
                self?.websockets.removeValue(forKey: ObjectIdentifier(connection))
                connection.cancel()
                return
            }
            self?.listenWebSocket(connection)
        }
    }

    private func respondJSON<T: Encodable>(_ connection: NWConnection, status: Int, value: T) {
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

    private static func websocketAccept(key: String) -> String {
        let magic = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
        let sha = Insecure.SHA1.hash(data: Data((key + magic).utf8))
        return Data(sha).base64EncodedString()
    }

    private static func wsTextFrame(_ text: String) -> Data {
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

enum Hostname {
    static func local() -> String? {
        var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard gethostname(&buffer, buffer.count) == 0 else { return nil }
        return String(cString: buffer)
    }
}
