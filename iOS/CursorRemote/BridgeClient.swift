import Foundation

@MainActor
final class BridgeClient: ObservableObject {
    @Published var status: SessionStatus?
    @Published var isConnected = false
    @Published var lastError: String?
    @Published var lastActionMessage: String?
    @Published var agents: [AgentConversation] = []
    @Published var agentHistory: [TranscriptMessage] = []
    @Published var agentHistoryForId: String?
    @Published var isLoadingCatalog = false
    @Published var isLoadingHistory = false
    @Published var isPerformingAction = false

    private var webSocketTask: URLSessionWebSocketTask?
    private let session: URLSession
    private var settings: BridgeSettings
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    init(settings: BridgeSettings) {
        self.settings = settings
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 90
        config.waitsForConnectivity = true
        session = URLSession(configuration: config)
    }

    func updateSettings(_ settings: BridgeSettings) {
        self.settings = settings
        disconnect()
    }

    func connect() {
        guard settings.baseURL != nil else {
            lastError = "Configure hostname and token in Settings"
            return
        }
        Task {
            await refreshStatus()
            openWebSocket()
        }
    }

    func disconnect() {
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        isConnected = false
    }

    func refreshStatus() async {
        do {
            let status: SessionStatus = try await get(path: "/session/status")
            self.status = status
            isConnected = true
            lastError = nil
        } catch {
            isConnected = false
            lastError = error.localizedDescription
        }
    }

    func sendPrompt(_ text: String) async {
        do {
            let response: ActionResponse = try await post(path: "/session/prompt", body: ["text": text])
            lastActionMessage = response.message
            if !response.success { lastError = response.message }
            await refreshStatus()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func approve() async {
        await performAction(path: "/session/approve")
    }

    func reject() async {
        await performAction(path: "/session/reject")
    }

    func registerDevice(token: String) async {
        do {
            let _: ActionResponse = try await post(
                path: "/devices/register",
                body: ["deviceToken": token, "bundleId": Bundle.main.bundleIdentifier ?? "com.jubblin.app.cursorremote"]
            )
        } catch {
            lastError = error.localizedDescription
        }
    }

    func loadAgentHistory(agentId: String, limit: Int = 20) async {
        isLoadingHistory = true
        defer { isLoadingHistory = false }
        do {
            let response: AgentHistoryResponse = try await get(path: "/agents/\(agentId)/history?limit=\(limit)")
            agentHistory = response.messages
            agentHistoryForId = agentId
            lastError = nil
        } catch {
            agentHistory = []
            agentHistoryForId = agentId
            lastError = error.localizedDescription
        }
    }

    func clearAgentHistory() {
        agentHistory = []
        agentHistoryForId = nil
    }

    func loadAgents() async {
        isLoadingCatalog = true
        defer { isLoadingCatalog = false }
        do {
            let response: AgentListResponse = try await get(path: "/agents")
            agents = response.agents.sorted { $0.lastUsedAt > $1.lastUsedAt }
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    func selectAgent(agentId: String) async {
        do {
            let body = SelectAgentRequest(agentId: agentId)
            let response: ActionResponse = try await postEncodable(path: "/agents/select", body: body)
            lastActionMessage = response.message
            if !response.success { lastError = response.message }
            await refreshStatus()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func loadProjects() async {
        await loadAgents()
    }

    func selectConversation(projectId _: String, conversationId: String) async {
        await selectAgent(agentId: conversationId)
    }

    private func performAction(path: String) async {
        isPerformingAction = true
        lastError = nil
        defer { isPerformingAction = false }

        let awaitingBefore = status?.state == .awaitingApproval

        do {
            let response: ActionResponse = try await post(path: path, body: [String: String](), isAction: true)
            lastActionMessage = response.message
            if response.success {
                lastError = nil
            } else {
                lastError = response.message
            }
            await refreshStatus()
        } catch {
            await refreshStatus()
            if awaitingBefore, status?.state != .awaitingApproval {
                lastActionMessage = "Action completed on Mac"
                lastError = nil
            } else if let urlError = error as? URLError, urlError.code == .timedOut {
                lastError = "Timed out waiting for Mac — check Cursor on your Mac"
            } else {
                lastError = error.localizedDescription
                lastActionMessage = nil
            }
        }
    }

    private func openWebSocket() {
        guard let base = settings.baseURL else { return }
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
        components?.scheme = settings.useHTTPS ? "wss" : "ws"
        components?.path = "/ws"
        guard let url = components?.url else { return }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(settings.token)", forHTTPHeaderField: "Authorization")

        let task = session.webSocketTask(with: request)
        webSocketTask = task
        task.resume()
        listen(task)
    }

    private func listen(_ task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case let .success(message):
                if case let .string(text) = message,
                   let data = text.data(using: .utf8),
                   let event = try? JSONDecoder().decode(WebSocketEvent.self, from: data),
                   let status = event.status {
                    Task { @MainActor in
                        self.status = status
                        self.isConnected = true
                    }
                }
                listen(task)
            case .failure:
                Task { @MainActor in
                    self.isConnected = false
                }
            }
        }
    }

    private func get<T: Decodable>(path: String) async throws -> T {
        guard let base = settings.baseURL else { throw BridgeError.misconfigured }
        var request = URLRequest(url: base.appendingPathComponent(path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))))
        request.setValue("Bearer \(settings.token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)
        return try decoder.decode(T.self, from: data)
    }

    private func post<T: Decodable>(path: String, body: [String: String], isAction: Bool = false) async throws -> T {
        guard let base = settings.baseURL else { throw BridgeError.misconfigured }
        var request = URLRequest(url: base.appendingPathComponent(path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(settings.token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        if isAction {
            request.timeoutInterval = 90
        }
        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)
        return try decoder.decode(T.self, from: data)
    }

    private func postEncodable<T: Decodable>(path: String, body: some Encodable) async throws -> T {
        guard let base = settings.baseURL else { throw BridgeError.misconfigured }
        var request = URLRequest(url: base.appendingPathComponent(path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(settings.token)", forHTTPHeaderField: "Authorization")
        let encoder = JSONEncoder()
        request.httpBody = try encoder.encode(body)
        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)
        return try decoder.decode(T.self, from: data)
    }

    private func validate(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw BridgeError.badResponse }
        guard (200 ... 299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw BridgeError.http(http.statusCode, body)
        }
    }
}

enum BridgeError: LocalizedError {
    case misconfigured
    case badResponse
    case http(Int, String)

    var errorDescription: String? {
        switch self {
        case .misconfigured: "Bridge not configured"
        case .badResponse: "Invalid server response"
        case let .http(code, body): "HTTP \(code): \(body)"
        }
    }
}
