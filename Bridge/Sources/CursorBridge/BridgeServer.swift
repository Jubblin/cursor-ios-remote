import CryptoKit
import Foundation
import Network

final class BridgeServer {
    private let port: UInt16
    private let authToken: String
    let automation = CursorAutomation()
    private let catalog = ConversationCatalog()
    private let pushService = PushNotificationService()
    let authLimiter = AuthRateLimiter()
    private var listener: NWListener?
    var websockets: [ObjectIdentifier: NWConnection] = [:]
    private var pollTimer: DispatchSourceTimer?
    private var lastStatus: SessionStatus?
    private let queue = DispatchQueue(label: "cursor.bridge.server")

    var onStatusUpdate: ((SessionStatus) -> Void)?
    private(set) var currentStatus: SessionStatus?

    init(port: Int, authToken: String) {
        self.port = UInt16(port)
        self.authToken = authToken
    }

    func start() throws {
        let bindAddress = BridgeSecurity.listenAddress()
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        guard let portEndpoint = NWEndpoint.Port(rawValue: port) else {
            throw BridgeServerError.invalidPort
        }
        params.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(bindAddress),
            port: portEndpoint
        )
        listener = try NWListener(using: params)
        listener?.newConnectionHandler = { [weak self] connection in
            self?.handle(connection: connection)
        }
        listener?.start(queue: queue)
        startPolling()
        if BridgeSecurity.bindsAllInterfaces(bindAddress) {
            print("[Bridge] Listening on \(bindAddress):\(port) (all interfaces — use Tailscale or set CURSOR_BRIDGE_BIND to restrict)")
        } else {
            print("[Bridge] Listening on \(bindAddress):\(port)")
        }
    }

    func stop() {
        pollTimer?.cancel()
        listener?.cancel()
        websockets.values.forEach { $0.cancel() }
        websockets.removeAll()
    }

    private var statusPollInFlight = false

    private func startPolling() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 4)
        timer.setEventHandler { [weak self] in
            self?.pollStatus()
        }
        timer.resume()
        pollTimer = timer
    }

    private func pollStatus() {
        guard !statusPollInFlight else { return }
        statusPollInFlight = true
        defer { statusPollInFlight = false }
        publishStatus(automation.detectSessionStatus(), shouldBroadcast: false)
    }

    private func refreshStatusAfterAction() {
        publishStatus(automation.detectSessionStatus(), shouldBroadcast: true)
    }

    private func publishStatus(_ status: SessionStatus, shouldBroadcast: Bool) {
        currentStatus = status
        onStatusUpdate?(status)
        let stateChanged = lastStatus?.state != status.state
        guard shouldBroadcast || stateChanged else { return }
        lastStatus = status
        broadcast(status)
        if status.state == .awaitingApproval {
            Task { await pushService.sendApprovalRequest(detail: status.detail) }
        }
    }

    private func broadcast(_ status: SessionStatus) {
        let event = WebSocketEvent(type: "status_changed", status: status)
        guard let data = try? JSONEncoder().encode(event),
              let json = String(data: data, encoding: .utf8) else { return }
        let frame = BridgeWebSocket.textFrame(json)
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
                receiveHTTP(on: connection, buffer: buffer)
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
                upgradeWebSocket(connection: connection, headers: headers, path: path)
                return
            }

            let contentLength = Int(headers["content-length"] ?? "0") ?? 0
            if contentLength > BridgeSecurity.maxHTTPBodyBytes {
                BridgeHTTP.respondJSON(connection, status: 413, value: ActionResponse(success: false, message: "Request body too large"))
                return
            }
            let body = bodyData
            if body.count < contentLength {
                readRemainingBody(
                    connection: connection,
                    needed: contentLength - body.count,
                    existing: body,
                    method: method,
                    path: path,
                    headers: headers
                )
                return
            }

            route(
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
        if needed > BridgeSecurity.maxHTTPBodyBytes || existing.count + needed > BridgeSecurity.maxHTTPBodyBytes {
            BridgeHTTP.respondJSON(connection, status: 413, value: ActionResponse(success: false, message: "Request body too large"))
            return
        }
        connection.receive(minimumIncompleteLength: needed, maximumLength: needed) { [weak self] data, _, _, _ in
            guard let self else { return }
            var body = existing
            if let data { body.append(data) }
            route(connection: connection, method: method, path: path, headers: headers, body: body)
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
            BridgeHTTP.respondJSON(connection, status: 200, value: ["ok": true])
            return
        }

        guard ensureAuthorized(connection: connection, headers: headers) else { return }

        let pathOnly = path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? path

        switch (method, pathOnly) {
        case ("GET", "/pairing"):
            BridgeHTTP.respondJSON(connection, status: 200, value: PairingInfo(
                token: authToken,
                port: Int(port),
                hostname: Hostname.local() ?? "localhost"
            ))
        case ("GET", "/agents"):
            BridgeHTTP.respondJSON(connection, status: 200, value: AgentListResponse(
                agents: catalog.listAgentConversations()
            ))
        case let ("GET", agentPath) where agentPath.hasPrefix("/agents/") && agentPath.hasSuffix("/history"):
            handleAgentHistory(connection: connection, agentPath: agentPath, path: path)
        case ("GET", "/projects"):
            let includeArchived = BridgeHTTP.queryFlag(path: path, name: "include_archived")
            BridgeHTTP.respondJSON(connection, status: 200, value: ProjectListResponse(
                projects: catalog.listProjects(includeArchived: includeArchived)
            ))
        case let ("GET", projectPath) where projectPath.hasPrefix("/projects/") && projectPath.hasSuffix("/conversations"):
            handleProjectConversations(connection: connection, projectPath: projectPath, path: path)
        case ("GET", "/session/status"):
            BridgeHTTP.respondJSON(connection, status: 200, value: automation.detectSessionStatus())
        case ("POST", "/session/prompt"):
            if let req = try? JSONDecoder().decode(PromptRequest.self, from: body) {
                BridgeHTTP.respondJSON(connection, status: 200, value: automation.sendPrompt(req.text))
            } else {
                BridgeHTTP.respondJSON(connection, status: 400, value: ActionResponse(success: false, message: "Invalid body"))
            }
        case ("POST", "/session/approve"):
            let result = automation.approve()
            print("[Bridge] approve: success=\(result.success) message=\(result.message)")
            BridgeHTTP.respondJSON(connection, status: 200, value: result)
            queue.async { [weak self] in self?.refreshStatusAfterAction() }
        case ("POST", "/session/reject"):
            let result = automation.reject()
            print("[Bridge] reject: success=\(result.success) message=\(result.message)")
            BridgeHTTP.respondJSON(connection, status: 200, value: result)
            queue.async { [weak self] in self?.refreshStatusAfterAction() }
        case ("POST", "/agents/select"):
            if let req = try? JSONDecoder().decode(SelectAgentRequest.self, from: body),
               let agent = catalog.agent(id: req.agentId),
               let workspacePath = agent.workspacePath {
                let result = automation.selectConversation(
                    workspacePath: workspacePath,
                    conversationName: agent.name
                )
                BridgeHTTP.respondJSON(connection, status: 200, value: result)
            } else {
                BridgeHTTP.respondJSON(connection, status: 400, value: ActionResponse(
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
                BridgeHTTP.respondJSON(connection, status: 200, value: result)
            } else {
                BridgeHTTP.respondJSON(
                    connection,
                    status: 400,
                    value: ActionResponse(success: false, message: "Invalid project or conversation")
                )
            }
        case ("POST", "/devices/register"):
            handleDeviceRegister(connection: connection, body: body)
        default:
            BridgeHTTP.respondJSON(connection, status: 404, value: ActionResponse(success: false, message: "Not found"))
        }
    }

    private func ensureAuthorized(connection: NWConnection, headers: [String: String]) -> Bool {
        let clientKey = connectionKey(connection)
        if authLimiter.isBlocked(key: clientKey) {
            BridgeHTTP.respondJSON(connection, status: 429, value: ActionResponse(success: false, message: "Too many failed auth attempts"))
            return false
        }
        if !authorized(headers: headers, clientKey: clientKey) {
            authLimiter.recordFailure(key: clientKey)
            BridgeHTTP.respondJSON(connection, status: 401, value: ActionResponse(success: false, message: "Unauthorized"))
            return false
        }
        authLimiter.reset(key: clientKey)
        return true
    }

    private func handleAgentHistory(connection: NWConnection, agentPath: String, path: String) {
        let parts = agentPath.split(separator: "/").map(String.init)
        guard parts.count == 3, parts[0] == "agents", parts[2] == "history" else {
            BridgeHTTP.respondJSON(connection, status: 400, value: ActionResponse(success: false, message: "Invalid path"))
            return
        }
        let agentId = parts[1]
        let limit = BridgeHTTP.queryInt(path: path, name: "limit") ?? 20
        if let history = AgentTranscriptReader.history(agentId: agentId, limit: limit) {
            BridgeHTTP.respondJSON(connection, status: 200, value: history)
        } else {
            BridgeHTTP.respondJSON(connection, status: 404, value: ActionResponse(success: false, message: "Agent history not found"))
        }
    }

    private func handleProjectConversations(connection: NWConnection, projectPath: String, path: String) {
        let parts = projectPath.split(separator: "/").map(String.init)
        guard parts.count == 3 else {
            BridgeHTTP.respondJSON(connection, status: 400, value: ActionResponse(success: false, message: "Invalid path"))
            return
        }
        let projectId = parts[1]
        let includeArchived = BridgeHTTP.queryFlag(path: path, name: "include_archived")
        if let list = catalog.listConversations(projectId: projectId, includeArchived: includeArchived) {
            BridgeHTTP.respondJSON(connection, status: 200, value: list)
        } else {
            BridgeHTTP.respondJSON(connection, status: 404, value: ActionResponse(success: false, message: "Project not found"))
        }
    }

    private func handleDeviceRegister(connection: NWConnection, body: Data) {
        guard let req = try? JSONDecoder().decode(DeviceRegistration.self, from: body) else {
            BridgeHTTP.respondJSON(connection, status: 400, value: ActionResponse(success: false, message: "Invalid body"))
            return
        }
        guard req.bundleId == BridgeSecurity.expectedIOSBundleId else {
            BridgeHTTP.respondJSON(connection, status: 400, value: ActionResponse(success: false, message: "Invalid bundle ID"))
            return
        }
        if pushService.register(token: req.deviceToken) {
            BridgeHTTP.respondJSON(connection, status: 200, value: ActionResponse(success: true, message: "Registered"))
        } else {
            BridgeHTTP.respondJSON(connection, status: 507, value: ActionResponse(success: false, message: "Device token limit reached"))
        }
    }

    func authorized(headers: [String: String], clientKey: String) -> Bool {
        guard let auth = headers["authorization"] else { return false }
        let expected = "Bearer \(authToken)"
        guard BridgeSecurity.constantTimeEqual(auth, expected) else { return false }
        _ = clientKey
        return true
    }

    func connectionKey(_ connection: NWConnection) -> String {
        if let endpoint = connection.currentPath?.remoteEndpoint {
            return "\(endpoint)"
        }
        return "\(ObjectIdentifier(connection))"
    }
}

enum BridgeServerError: Error {
    case invalidPort
}
