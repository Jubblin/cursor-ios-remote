import Foundation

enum AgentSessionState: String, Codable, Sendable {
    case unknown
    case idle
    case running
    case awaitingApproval = "awaiting_approval"
    case error

    var displayName: String {
        switch self {
        case .unknown: "Unknown"
        case .idle: "Idle"
        case .running: "Running"
        case .awaitingApproval: "Needs approval"
        case .error: "Error"
        }
    }

    var symbolName: String {
        switch self {
        case .awaitingApproval: "hand.raised.fill"
        case .running: "bolt.fill"
        case .idle: "moon.fill"
        case .error: "exclamationmark.triangle.fill"
        case .unknown: "questionmark.circle"
        }
    }
}

struct SessionStatus: Codable, Sendable {
    let state: AgentSessionState
    let detail: String?
    let cursorRunning: Bool
    let updatedAt: Date
}

struct ActionResponse: Codable, Sendable {
    let success: Bool
    let message: String
}

struct WebSocketEvent: Codable, Sendable {
    let type: String
    let status: SessionStatus?
}

struct BridgeSettings: Codable, Equatable {
    var hostname: String
    var port: Int
    var token: String
    var useHTTPS: Bool
    var selectedAgentId: String?

    static let `default` = BridgeSettings(
        hostname: "",
        port: 8742,
        token: "",
        useHTTPS: false,
        selectedAgentId: nil
    )

    var baseURL: URL? {
        guard !hostname.isEmpty else { return nil }
        let scheme = useHTTPS ? "https" : "http"
        return URL(string: "\(scheme)://\(hostname):\(port)")
    }
}

struct AgentConversation: Codable, Identifiable, Hashable {
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

struct AgentListResponse: Codable {
    let agents: [AgentConversation]
}

struct SelectAgentRequest: Codable {
    let agentId: String
}

struct TranscriptMessage: Codable, Identifiable, Hashable {
    let id: Int
    let role: String
    let text: String

    var isUser: Bool {
        role == "user"
    }

    var roleLabel: String {
        isUser ? "You" : "Agent"
    }
}

struct AgentHistoryResponse: Codable {
    let agentId: String
    let messages: [TranscriptMessage]
}

struct CursorProject: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let path: String
    let conversationCount: Int
    let lastActivity: Date?

    var lastUsedAt: Date {
        lastActivity ?? .distantPast
    }
}

struct CursorConversation: Codable, Identifiable, Hashable {
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

struct ProjectListResponse: Codable {
    let projects: [CursorProject]
}

struct ConversationListResponse: Codable {
    let projectId: String
    let conversations: [CursorConversation]
}

struct SelectConversationRequest: Codable {
    let projectId: String
    let conversationId: String
}
