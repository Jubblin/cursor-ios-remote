import Foundation

enum AgentSessionState: String, Codable, Sendable {
    case unknown
    case idle
    case running
    case awaitingApproval = "awaiting_approval"
    case error
}

struct SessionStatus: Codable, Sendable {
    let state: AgentSessionState
    let detail: String?
    let cursorRunning: Bool
    let updatedAt: Date

    init(
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

struct PromptRequest: Codable, Sendable {
    let text: String
}

struct ActionResponse: Codable, Sendable {
    let success: Bool
    let message: String
}

struct PairingInfo: Codable, Sendable {
    let token: String
    let port: Int
    let hostname: String
}

struct DeviceRegistration: Codable, Sendable {
    let deviceToken: String
    let bundleId: String
}

struct BridgeHealth: Codable, Sendable {
    let ok: Bool
    let version: String
    let uptimeSeconds: Int
}

struct AgentConversation: Codable, Sendable, Identifiable {
    let id: String
    let projectSlug: String
    let projectName: String
    let projectId: String?
    let workspacePath: String?
    let name: String
    let createdAt: Date?
    let lastUpdatedAt: Date?
    let source: String

    var lastUsedAt: Date {
        lastUpdatedAt ?? createdAt ?? .distantPast
    }
}

struct AgentListResponse: Codable, Sendable {
    let agents: [AgentConversation]
}

struct SelectAgentRequest: Codable, Sendable {
    let agentId: String
}

struct CursorProject: Codable, Sendable, Identifiable {
    let id: String
    let name: String
    let path: String
    let conversationCount: Int
    let lastActivity: Date?

    var lastUsedAt: Date {
        lastActivity ?? .distantPast
    }
}

struct CursorConversation: Codable, Sendable, Identifiable {
    let id: String
    let projectId: String
    let name: String
    let subtitle: String?
    let mode: String?
    let branch: String?
    let createdAt: Date?
    let lastUpdatedAt: Date?
    let isArchived: Bool
    let source: String

    var lastUsedAt: Date {
        lastUpdatedAt ?? createdAt ?? .distantPast
    }
}

struct ProjectListResponse: Codable, Sendable {
    let projects: [CursorProject]
}

struct ConversationListResponse: Codable, Sendable {
    let projectId: String
    let conversations: [CursorConversation]
}

struct SelectConversationRequest: Codable, Sendable {
    let projectId: String
    let conversationId: String
}

struct WebSocketEvent: Codable, Sendable {
    let type: String
    let status: SessionStatus?
}
