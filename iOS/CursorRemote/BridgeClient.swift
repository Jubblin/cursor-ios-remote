import Foundation

@MainActor
final class BridgeClient: ObservableObject {
    @Published var status: SessionStatus?
    @Published var isConnected = false
    @Published var lastError: String?
    @Published var lastActionMessage: String?
    @Published var agents: [AgentConversation] = []
    @Published var isLoadingCatalog = false

    private var webSocketTask: URLSessionWebSocketTask?
    private let session = URLSession(configuration: .default)
    private var settings: BridgeSettings
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    init(settings: BridgeSettings) {
        self.settings = settings
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
                body: ["deviceToken": token, "bundleId": Bundle.main.bundleIdentifier ?? "com.cursorremote.app"]
            )
        } catch {
            lastError = error.localizedDescription
        }
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
        do {
            let response: ActionResponse = try await post(path: path, body: [String: String]())
            lastActionMessage = response.message
            if !response.success { lastError = response.message }
            await refreshStatus()
        } catch {
            lastError = error.localizedDescription
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

    private func post<T: Decodable>(path: String, body: [String: String]) async throws -> T {
        guard let base = settings.baseURL else { throw BridgeError.misconfigured }
        var request = URLRequest(url: base.appendingPathComponent(path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(settings.token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
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
