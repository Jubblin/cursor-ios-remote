import Foundation
import SQLite3

final class ConversationCatalog {
    private let cursorSupport = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Cursor/User")
    private let projectsRoot = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".cursor/projects")

    func listAgentConversations() -> [AgentConversation] {
        let slugIndex = buildSlugIndex()
        guard let slugs = try? FileManager.default.contentsOfDirectory(
            atPath: projectsRoot.path
        ) else { return [] }

        var results: [AgentConversation] = []
        for slug in slugs {
            let transcriptsRoot = projectsRoot
                .appendingPathComponent(slug)
                .appendingPathComponent("agent-transcripts")
            guard FileManager.default.fileExists(atPath: transcriptsRoot.path),
                  let sessions = try? FileManager.default.contentsOfDirectory(
                    at: transcriptsRoot,
                    includingPropertiesForKeys: [.contentModificationDateKey],
                    options: [.skipsHiddenFiles]
                  ) else { continue }

            let resolved = slugIndex[slug]
            let projectName = projectDisplayName(slug: slug, folderPath: resolved?.folderPath)

            for sessionDir in sessions where sessionDir.hasDirectoryPath {
                let agentId = sessionDir.lastPathComponent
                let jsonlFiles = (try? FileManager.default.contentsOfDirectory(at: sessionDir, includingPropertiesForKeys: nil))?
                    .filter { $0.pathExtension == "jsonl" } ?? []
                guard let jsonl = jsonlFiles.first else { continue }

                let attrs = try? FileManager.default.attributesOfItem(atPath: jsonl.path)
                let modified = attrs?[.modificationDate] as? Date
                let title = transcriptTitle(jsonl) ?? "Agent session \(agentId.prefix(8))"

                results.append(AgentConversation(
                    id: agentId,
                    projectSlug: slug,
                    projectName: projectName,
                    projectId: resolved?.projectId,
                    workspacePath: resolved?.folderPath,
                    name: title,
                    createdAt: modified,
                    lastUpdatedAt: modified,
                    source: "agent-transcript"
                ))
            }
        }

        return results.sorted { $0.lastUsedAt > $1.lastUsedAt }
    }

    func agent(id: String) -> AgentConversation? {
        listAgentConversations().first { $0.id == id }
    }

    func listProjects(includeArchived: Bool = false) -> [CursorProject] {
        let workspaceRoot = cursorSupport.appendingPathComponent("workspaceStorage")
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: workspaceRoot,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var projects: [CursorProject] = []
        for entry in entries {
            guard entry.hasDirectoryPath else { continue }
            let workspaceJSON = entry.appendingPathComponent("workspace.json")
            let dbPath = entry.appendingPathComponent("state.vscdb")
            guard FileManager.default.fileExists(atPath: workspaceJSON.path),
                  FileManager.default.fileExists(atPath: dbPath.path) else { continue }

            guard let folderPath = workspaceFolderPath(workspaceJSON) else { continue }
            let conversations = loadComposerConversations(
                dbPath: dbPath,
                projectId: entry.lastPathComponent,
                includeArchived: includeArchived
            ).conversations
            guard !conversations.isEmpty else { continue }

            let lastActivity = conversations.map(\.lastUsedAt).max()
            projects.append(CursorProject(
                id: entry.lastPathComponent,
                name: URL(fileURLWithPath: folderPath).lastPathComponent,
                path: folderPath,
                conversationCount: conversations.count,
                lastActivity: lastActivity
            ))
        }

        return projects.sorted { $0.lastUsedAt > $1.lastUsedAt }
    }

    func listConversations(projectId: String, includeArchived: Bool = false) -> ConversationListResponse? {
        guard let project = resolveProject(projectId: projectId) else { return nil }
        let (conversations, recencyOrder) = loadComposerConversations(
            dbPath: project.dbPath,
            projectId: projectId,
            includeArchived: includeArchived
        )
        let transcriptConversations = loadAgentTranscripts(projectSlug: project.slug, projectId: projectId)
        var merged = conversations
        let existing = Set(conversations.map(\.id))
        for item in transcriptConversations where !existing.contains(item.id) {
            merged.append(item)
        }
        let sorted = sortByLastUsed(merged, recencyOrder: recencyOrder)
        return ConversationListResponse(projectId: projectId, conversations: sorted)
    }

    func conversation(projectId: String, conversationId: String) -> CursorConversation? {
        listConversations(projectId: projectId, includeArchived: true)?
            .conversations
            .first { $0.id == conversationId }
    }

    func projectPath(projectId: String) -> String? {
        resolveProject(projectId: projectId)?.folderPath
    }

    // MARK: - Private

    private struct ResolvedProject {
        let projectId: String
        let folderPath: String
        let dbPath: URL
        let slug: String?
    }

    private func buildSlugIndex() -> [String: ResolvedProject] {
        let workspaceRoot = cursorSupport.appendingPathComponent("workspaceStorage")
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: workspaceRoot,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [:] }

        var index: [String: ResolvedProject] = [:]
        for entry in entries where entry.hasDirectoryPath {
            let workspaceJSON = entry.appendingPathComponent("workspace.json")
            let dbPath = entry.appendingPathComponent("state.vscdb")
            guard let folderPath = workspaceFolderPath(workspaceJSON) else { continue }
            let slug = slugForFolderPath(folderPath)
            let resolved = ResolvedProject(
                projectId: entry.lastPathComponent,
                folderPath: folderPath,
                dbPath: dbPath,
                slug: slug
            )
            index[slug] = resolved
            if let fuzzy = projectSlug(for: folderPath), fuzzy != slug {
                index[fuzzy] = resolved
            }
        }
        return index
    }

    private func slugForFolderPath(_ folderPath: String) -> String {
        folderPath
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: " ", with: "-")
    }

    private func projectDisplayName(slug: String, folderPath: String?) -> String {
        if let folderPath {
            return URL(fileURLWithPath: folderPath).lastPathComponent
        }
        let parts = slug.split(separator: "-")
        guard parts.count > 2 else { return slug }
        return parts.dropFirst(2).joined(separator: " ")
    }

    private struct ResolvedProjectLegacy {
        let folderPath: String
        let dbPath: URL
        let slug: String?
    }

    private func resolveProject(projectId: String) -> ResolvedProjectLegacy? {
        let workspaceDir = cursorSupport
            .appendingPathComponent("workspaceStorage/\(projectId)")
        let workspaceJSON = workspaceDir.appendingPathComponent("workspace.json")
        let dbPath = workspaceDir.appendingPathComponent("state.vscdb")
        guard let folderPath = workspaceFolderPath(workspaceJSON) else { return nil }
        return ResolvedProjectLegacy(
            folderPath: folderPath,
            dbPath: dbPath,
            slug: projectSlug(for: folderPath)
        )
    }

    private func workspaceFolderPath(_ workspaceJSON: URL) -> String? {
        guard let data = try? Data(contentsOf: workspaceJSON),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if let folder = json["folder"] as? String {
            return folder.replacingOccurrences(of: "file://", with: "")
                .removingPercentEncoding
        }
        if let folder = json["folderUri"] as? String {
            return folder.replacingOccurrences(of: "file://", with: "")
                .removingPercentEncoding
        }
        return nil
    }

    private func projectSlug(for folderPath: String) -> String? {
        let normalized = folderPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let slug = normalized
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: " ", with: "-")
        let candidate = projectsRoot.appendingPathComponent(slug)
        if FileManager.default.fileExists(atPath: candidate.path) {
            return slug
        }
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: projectsRoot.path) else {
            return nil
        }
        let folderName = URL(fileURLWithPath: folderPath).lastPathComponent.lowercased()
        return entries.first { $0.lowercased().contains(folderName) }
    }

    private func loadComposerConversations(
        dbPath: URL,
        projectId: String,
        includeArchived: Bool
    ) -> (conversations: [CursorConversation], recencyOrder: [String]) {
        guard let jsonText = sqliteString(dbPath: dbPath, key: "composer.composerData"),
              let data = jsonText.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let allComposers = root["allComposers"] as? [[String: Any]] else {
            return ([], [])
        }

        let focused = root["lastFocusedComposerIds"] as? [String] ?? []
        let selected = root["selectedComposerIds"] as? [String] ?? []
        var recencyOrder: [String] = []
        for id in focused + selected where !recencyOrder.contains(id) {
            recencyOrder.append(id)
        }

        let conversations = allComposers.compactMap { item -> CursorConversation? in
            guard let composerId = item["composerId"] as? String else { return nil }
            let isArchived = item["isArchived"] as? Bool ?? false
            if isArchived && !includeArchived { return nil }

            let name = (item["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let subtitle = item["subtitle"] as? String
            let displayName: String
            if let name, !name.isEmpty {
                displayName = name
            } else if let subtitle, !subtitle.isEmpty {
                displayName = subtitle
            } else {
                displayName = "Untitled chat"
            }

            return CursorConversation(
                id: composerId,
                projectId: projectId,
                name: displayName,
                subtitle: subtitle,
                mode: item["unifiedMode"] as? String,
                branch: item["createdOnBranch"] as? String,
                createdAt: msDate(item["createdAt"]),
                lastUpdatedAt: msDate(item["lastUpdatedAt"]),
                isArchived: isArchived,
                source: "composer"
            )
        }

        return (sortByLastUsed(conversations, recencyOrder: recencyOrder), recencyOrder)
    }

    private func loadAgentTranscripts(projectSlug: String?, projectId: String) -> [CursorConversation] {
        guard let projectSlug else { return [] }
        let transcriptsRoot = projectsRoot
            .appendingPathComponent(projectSlug)
            .appendingPathComponent("agent-transcripts")
        guard let sessions = try? FileManager.default.contentsOfDirectory(
            at: transcriptsRoot,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var results: [CursorConversation] = []
        for sessionDir in sessions where sessionDir.hasDirectoryPath {
            let jsonlFiles = (try? FileManager.default.contentsOfDirectory(at: sessionDir, includingPropertiesForKeys: nil))?
                .filter { $0.pathExtension == "jsonl" } ?? []
            guard let jsonl = jsonlFiles.first else { continue }

            let attrs = try? FileManager.default.attributesOfItem(atPath: jsonl.path)
            let modified = attrs?[.modificationDate] as? Date
            let title = transcriptTitle(jsonl) ?? "Agent session \(sessionDir.lastPathComponent.prefix(8))"

            results.append(CursorConversation(
                id: sessionDir.lastPathComponent,
                projectId: projectId,
                name: title,
                subtitle: "Agent transcript",
                mode: "agent",
                branch: nil,
                createdAt: modified,
                lastUpdatedAt: modified,
                isArchived: false,
                source: "agent-transcript"
            ))
        }
        return sortByLastUsed(results, recencyOrder: [])
    }

    private func sortByLastUsed(_ conversations: [CursorConversation], recencyOrder: [String]) -> [CursorConversation] {
        let rank = Dictionary(uniqueKeysWithValues: recencyOrder.enumerated().map { ($1, $0) })
        return conversations.sorted { lhs, rhs in
            let lhsRank = rank[lhs.id] ?? Int.max
            let rhsRank = rank[rhs.id] ?? Int.max
            if lhsRank != rhsRank { return lhsRank < rhsRank }
            return lhs.lastUsedAt > rhs.lastUsedAt
        }
    }

    private func transcriptTitle(_ jsonl: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: jsonl),
              let lineData = try? handle.readToEnd(),
              let line = String(data: lineData, encoding: .utf8)?.split(separator: "\n").first else {
            return nil
        }
        guard let json = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let message = json["message"] as? [String: Any],
              let content = message["content"] as? [[String: Any]] else {
            return nil
        }
        for block in content {
            guard let type = block["type"] as? String, type == "text",
                  let text = block["text"] as? String else { continue }
            if let range = text.range(of: "<user_query>"),
               let end = text.range(of: "</user_query>") {
                let query = String(text[range.upperBound ..< end.lowerBound])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !query.isEmpty { return String(query.prefix(80)) }
            }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return String(trimmed.prefix(80)) }
        }
        return nil
    }

    private func sqliteString(dbPath: URL, key: String) -> String? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let db else { return nil }
        defer { sqlite3_close(db) }

        let sql = "SELECT value FROM ItemTable WHERE key = ? LIMIT 1;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return nil }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, key, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        guard let cString = sqlite3_column_text(stmt, 0) else { return nil }
        return String(cString: cString)
    }

    private func msDate(_ value: Any?) -> Date? {
        if let ms = value as? Double { return Date(timeIntervalSince1970: ms / 1000) }
        if let ms = value as? Int { return Date(timeIntervalSince1970: Double(ms) / 1000) }
        if let ms = value as? Int64 { return Date(timeIntervalSince1970: Double(ms) / 1000) }
        return nil
    }
}
