import Foundation

enum AgentTranscriptReader {
    private static let projectsRoot = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".cursor/projects")
    private static let maxReadBytes = 2_000_000

    static func history(agentId: String, limit: Int) -> AgentHistoryResponse? {
        guard let jsonl = transcriptURL(for: agentId) else { return nil }
        let cappedLimit = min(max(limit, 1), 50)
        let lines = readTailLines(from: jsonl)
        var messages: [TranscriptMessage] = []
        for (offset, line) in lines.enumerated() {
            guard let message = parseLine(line, index: offset) else { continue }
            messages.append(message)
        }
        return AgentHistoryResponse(agentId: agentId, messages: Array(messages.suffix(cappedLimit)))
    }

    static func transcriptURL(for agentId: String) -> URL? {
        guard let slugs = try? FileManager.default.contentsOfDirectory(atPath: projectsRoot.path) else {
            return nil
        }
        for slug in slugs {
            let sessionDir = projectsRoot
                .appendingPathComponent(slug)
                .appendingPathComponent("agent-transcripts")
                .appendingPathComponent(agentId)
            guard FileManager.default.fileExists(atPath: sessionDir.path) else { continue }
            let jsonlFiles = (try? FileManager.default.contentsOfDirectory(at: sessionDir, includingPropertiesForKeys: nil))?
                .filter { $0.pathExtension == "jsonl" } ?? []
            if let jsonl = jsonlFiles.first { return jsonl }
        }
        return nil
    }

    private static func readTailLines(from url: URL) -> [String] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }

        let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64) ?? 0
        let readSize = Int(min(UInt64(maxReadBytes), fileSize))
        guard readSize > 0 else { return [] }

        try? handle.seek(toOffset: UInt64(max(0, Int(fileSize) - readSize)))
        guard let data = try? handle.readToEnd(),
              let text = String(data: data, encoding: .utf8) else { return [] }

        var lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        if readSize < Int(fileSize), let first = lines.first, !first.hasPrefix("{") {
            lines.removeFirst()
        }
        return lines
    }

    private static func parseLine(_ line: String, index: Int) -> TranscriptMessage? {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let role = json["role"] as? String,
              let message = json["message"] as? [String: Any],
              let content = message["content"] as? [[String: Any]] else { return nil }

        let text = displayText(from: content, role: role)
        guard !text.isEmpty else { return nil }
        return TranscriptMessage(id: index, role: role, text: text)
    }

    private static func displayText(from content: [[String: Any]], role: String) -> String {
        var parts: [String] = []
        for block in content {
            guard let type = block["type"] as? String, type == "text",
                  let raw = block["text"] as? String else { continue }
            let cleaned = cleanText(raw, role: role)
            if !cleaned.isEmpty { parts.append(cleaned) }
        }
        let joined = parts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard joined.count > 600 else { return joined }
        return String(joined.prefix(600)) + "…"
    }

    private static func cleanText(_ text: String, role: String) -> String {
        var result = text
        if let start = result.range(of: "<user_query>"),
           let end = result.range(of: "</user_query>") {
            result = String(result[start.upperBound ..< end.lowerBound])
        }
        if role == "user", result.contains("<manually_attached_skills>"),
           let end = result.range(of: "</manually_attached_skills>") {
            result = String(result[end.upperBound...])
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
