import Foundation

public enum AgentSessionState: String, Codable, Sendable {
    case unknown
    case idle
    case running
    case awaitingApproval = "awaiting_approval"
    case error
}

public struct SessionStatus: Codable, Sendable {
    public let state: AgentSessionState
    public let detail: String?
    public let cursorRunning: Bool
    public let updatedAt: Date

    public init(
        state: AgentSessionState,
        detail: String? = nil,
        cursorRunning: Bool,
        updatedAt: Date = Date()
    ) {
        self.state = state
        self.detail = detail
        self.cursorRunning = cursorRunning
        self.updatedAt = updatedAt
    }
}

public struct PromptRequest: Codable, Sendable {
    public let text: String
}

public struct ActionResponse: Codable, Sendable {
    public let success: Bool
    public let message: String
}

public struct PairingInfo: Codable, Sendable {
    public let token: String
    public let port: Int
    public let hostname: String
}

public struct DeviceRegistration: Codable, Sendable {
    public let deviceToken: String
    public let bundleId: String
}

public struct BridgeHealth: Codable, Sendable {
    public let ok: Bool
    public let version: String
    public let uptimeSeconds: Int
}

public struct WebSocketEvent: Codable, Sendable {
    public let type: String
    public let status: SessionStatus?
}
