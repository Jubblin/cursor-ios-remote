import Foundation

enum AgentSessionState: String, Codable, Sendable {
    case unknown
    case idle
    case running
    case awaitingApproval = "awaiting_approval"
    case error

    var displayName: String {
        switch self {
        case .unknown: return "Unknown"
        case .idle: return "Idle"
        case .running: return "Running"
        case .awaitingApproval: return "Needs approval"
        case .error: return "Error"
        }
    }

    var symbolName: String {
        switch self {
        case .awaitingApproval: return "hand.raised.fill"
        case .running: return "bolt.fill"
        case .idle: return "moon.fill"
        case .error: return "exclamationmark.triangle.fill"
        case .unknown: return "questionmark.circle"
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
