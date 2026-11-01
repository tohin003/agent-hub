import Foundation

/// Finds the conversation file an agent writes, and lists an account's past conversations.
enum TranscriptLocator {
    // MARK: Claude

    static func claudeFile(dataDir: String, sessionId: String) -> URL? {
        let projects = URL(fileURLWithPath: dataDir).appending(path: "projects")
        guard let folders = try? FileManager.default.contentsOfDirectory(atPath: projects.path) else { return nil }
        for folder in folders {
            let file = projects.appending(path: folder).appending(path: "\(sessionId).jsonl")
            if FileManager.default.fileExists(atPath: file.path) { return file }
        }
        return nil
    }

    // MARK: Codex

    /// The rollout a newly started Codex writes: the newest one for this folder created after `since`.
    static func codexRollout(dataDir: String, cwd: String, since: Date, resumeId: String?, excluding: Set<String>) -> URL? {
        let sessions = URL(fileURLWithPath: dataDir).appending(path: "sessions")
        if let resumeId {
            return rollouts(in: sessions, limit: 400).first { $0.lastPathComponent.contains(resumeId) }
        }
        let calendar = Calendar.current
        var candidates: [URL] = []
        for dayOffset in [0, -1] {
            guard let day = calendar.date(byAdding: .day, value: dayOffset, to: .now) else { continue }
            let parts = calendar.dateComponents([.year, .month, .day], from: day)
            let folder = sessions.appending(path: String(format: "%04d/%02d/%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0))
            let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            candidates += files.filter { $0.pathExtension == "jsonl" }
        }
        let resolved = (cwd as NSString).resolvingSymlinksInPath
        let recent = candidates.compactMap { url -> (URL, Date)? in
            guard !excluding.contains(url.path),
                  let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                  date >= since.addingTimeInterval(-10) else { return nil }
            return (url, date)
        }.sorted { $0.1 > $1.1 }
        for (url, _) in recent {
            guard let meta = firstJSONLine(url), let payload = meta["payload"] as? [String: Any],
                  let metaCwd = payload["cwd"] as? String else { continue }
            if metaCwd == cwd || (metaCwd as NSString).resolvingSymlinksInPath == resolved { return url }
        }
        return nil
    }

    static func rollouts(in folder: URL, limit: Int) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.contentModificationDateKey],
                                                              options: [.skipsHiddenFiles]) else { return [] }
        var files: [(URL, Date)] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" && url.lastPathComponent.hasPrefix("rollout-") {
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            files.append((url, date))
        }
        return files.sorted { $0.1 > $1.1 }.prefix(limit).map(\.0)
    }

    static func firstJSONLine(_ url: URL) -> [String: Any]? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 256 * 1024),
              let newline = data.firstIndex(of: 0x0A) ?? (data.isEmpty ? nil : data.endIndex) else { return nil }
        return try? JSONSerialization.jsonObject(with: data[data.startIndex..<newline]) as? [String: Any]
    }

    static func headLines(_ url: URL, bytes: Int = 256 * 1024) -> [[String: Any]] {
        guard let handle = try? FileHandle(forReadingFrom: url), let data = try? handle.read(upToCount: bytes) else { return [] }
        try? handle.close()
        return data.split(separator: 0x0A).compactMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }

    static func tailLines(_ url: URL, bytes: UInt64 = 256 * 1024) -> [[String: Any]] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > bytes ? size - bytes : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd() else { return [] }
        var lines = data.split(separator: 0x0A)
        if start > 0, !lines.isEmpty { lines.removeFirst() }
        return lines.compactMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }

    /// The first (or last) JSON line containing `marker`, reading at most `limit` bytes from the start (or end).
    /// Only lines with the marker are parsed, so large files stay cheap.
    static func scan(_ url: URL, marker: String, fromEnd: Bool, limit: Int = 4 * 1024 * 1024) -> [String: Any]? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let size = Int((try? handle.seekToEnd()) ?? 0)
        let start = fromEnd ? max(0, size - limit) : 0
        try? handle.seek(toOffset: UInt64(start))
        guard let data = try? handle.read(upToCount: min(limit, size - start)) else { return nil }
        let needle = Data(marker.utf8)
        var lines = data.split(separator: 0x0A, omittingEmptySubsequences: true)
        if fromEnd, start > 0, !lines.isEmpty { lines.removeFirst() }
        let ordered: [Data.SubSequence] = fromEnd ? lines.reversed() : lines
        for line in ordered where line.range(of: needle) != nil {
            if let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] { return object }
        }
        return nil
    }

    /// The first message you typed in a Codex rollout, skipping the context Codex adds as user messages.
    static func firstCodexUserText(_ url: URL, limit: Int = 4 * 1024 * 1024) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url), let data = try? handle.read(upToCount: limit) else { return nil }
        try? handle.close()
        let needle = Data("\"role\":\"user\"".utf8)
        for line in data.split(separator: 0x0A) where line.range(of: needle) != nil {
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let payload = object["payload"] as? [String: Any] else { continue }
            let text = CodexTranscript.messageText(payload["content"]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, !text.hasPrefix("<"), !text.hasPrefix("# AGENTS.md") else { continue }
            return text
        }
        return nil
    }

    // MARK: History

    static func history(for account: Account, limit: Int) -> [HistoryEntry] {
        guard let dataDir = account.dataDir else { return [] }
        let entries: [HistoryEntry]
        switch account.provider {
        case .claude: entries = claudeHistory(account: account, dataDir: dataDir, limit: limit + 4)
        case .codex: entries = codexHistory(account: account, dataDir: dataDir, limit: limit + 4)
        case .opencode: entries = openCodeHistory(account: account, dataDir: dataDir, limit: limit + 4)
        case .antigravity: entries = antigravityHistory(account: account, dataDir: dataDir, limit: limit + 4)
        case .gemini, .shell, .other: entries = []
        }
        // The hub's own probe folder (logos, model lists) isn't your work.
        let probe = "\(HubPaths.root)/probe"
        return Array(entries.filter { entry in
            guard let cwd = entry.cwd else { return true }
            return cwd != probe && !cwd.hasPrefix(probe + "/")
        }.prefix(limit))
    }

    private static func claudeHistory(account: Account, dataDir: String, limit: Int) -> [HistoryEntry] {
        let projects = URL(fileURLWithPath: dataDir).appending(path: "projects")
        let fm = FileManager.default
        guard let folders = try? fm.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil) else { return [] }
        var files: [(URL, Date, Int64)] = []
        for folder in folders {
            guard let entries = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]) else { continue }
            for url in entries where url.pathExtension == "jsonl" {
                let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                files.append((url, values?.contentModificationDate ?? .distantPast, Int64(values?.fileSize ?? 0)))
            }
        }
        files.sort { $0.1 > $1.1 }
        return files.prefix(limit).compactMap { url, date, size in
            let head = headLines(url, bytes: 128 * 1024)
            var cwd: String?
            var prompt: String?
            for line in head {
                if cwd == nil { cwd = line["cwd"] as? String }
                if prompt == nil, line["type"] as? String == "user", line["isMeta"] as? Bool != true,
                   let message = line["message"] as? [String: Any] {
                    let text = (message["content"] as? String) ?? ((message["content"] as? [[String: Any]])?
                        .compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator: " "))
                    if let text, !text.contains("<command-name>"), !text.contains("<local-command"), !text.hasPrefix("<"),
                       !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        prompt = text
                    }
                }
                if cwd != nil, prompt != nil { break }
            }
            let tail = tailLines(url, bytes: 192 * 1024)
            let title = tail.reversed().first { $0["type"] as? String == "ai-title" }?["aiTitle"] as? String
            if cwd == nil {
                cwd = tail.reversed().lazy.compactMap { $0["cwd"] as? String }.first
                    ?? scan(url, marker: "\"cwd\"", fromEnd: false)?["cwd"] as? String
            }
            guard size > 0, title != nil || prompt != nil || cwd != nil else { return nil }
            let settings = claudeSettings(tail: tail, head: head)
            return HistoryEntry(id: url.deletingPathExtension().lastPathComponent, accountId: account.id,
                                title: title ?? Clip.oneLine(prompt ?? "Conversation", limit: 90), cwd: cwd, updatedAt: date,
                                sizeBytes: size, mode: settings.mode, model: settings.model, effort: settings.effort,
                                settings: describe(settings), activeElsewhere: Date.now.timeIntervalSince(date) < 120)
        }
    }

    private static func codexHistory(account: Account, dataDir: String, limit: Int) -> [HistoryEntry] {
        let files = rollouts(in: URL(fileURLWithPath: dataDir).appending(path: "sessions"), limit: limit)
        return files.compactMap { url in
            let head = headLines(url, bytes: 192 * 1024)
            guard let meta = head.first?["payload"] as? [String: Any], let id = meta["id"] as? String else { return nil }
            var prompt: String?
            for line in head where line["type"] as? String == "event_msg" {
                if let payload = line["payload"] as? [String: Any], payload["type"] as? String == "user_message",
                   let message = payload["message"] as? String {
                    prompt = message
                    break
                }
            }
            if prompt == nil {
                prompt = (scan(url, marker: "\"user_message\"", fromEnd: false)?["payload"] as? [String: Any])?["message"] as? String
            }
            if prompt == nil {
                // Conversations started in the Codex app record your message as a plain user item.
                prompt = firstCodexUserText(url)
            }
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            let context = ((tailLines(url, bytes: 256 * 1024) + head).reversed()
                .first { $0["type"] as? String == "turn_context" }
                ?? scan(url, marker: "\"turn_context\"", fromEnd: true))?["payload"] as? [String: Any]
            let settings = codexSettings(context)
            let updated = values?.contentModificationDate
            return HistoryEntry(id: id, accountId: account.id, title: Clip.oneLine(prompt ?? "Codex conversation", limit: 90),
                                cwd: context?["cwd"] as? String ?? meta["cwd"] as? String, updatedAt: updated,
                                sizeBytes: Int64(values?.fileSize ?? 0), mode: settings.mode, model: settings.model,
                                effort: settings.effort, settings: describe(settings),
                                activeElsewhere: updated.map { Date.now.timeIntervalSince($0) < 120 })
        }
    }

    private static func openCodeHistory(account: Account, dataDir: String, limit: Int) -> [HistoryEntry] {
        guard let db = SQLiteReader(path: "\(dataDir)/opencode.db") else { return [] }
        return db.query("SELECT id, title, directory, time_updated FROM session WHERE parent_id IS NULL ORDER BY time_updated DESC LIMIT ?",
                        [limit]).compactMap { row in
            guard let id = row["id"] as? String else { return nil }
            let last = db.query("SELECT json_extract(data, '$.providerID') AS provider, json_extract(data, '$.modelID') AS model FROM message WHERE session_id = ? AND json_extract(data, '$.role') = 'assistant' ORDER BY time_created DESC LIMIT 1",
                                [id]).first
            let model: String? = {
                guard let modelID = last?["model"] as? String else { return nil }
                if let provider = last?["provider"] as? String { return "\(provider)/\(modelID)" }
                return modelID
            }()
            let updated = Stamp.parse(row["time_updated"])
            return HistoryEntry(id: id, accountId: account.id, title: (row["title"] as? String)?.nilIfEmpty ?? "OpenCode session",
                                cwd: row["directory"] as? String, updatedAt: updated, sizeBytes: nil, model: model,
                                settings: model, activeElsewhere: updated.map { Date.now.timeIntervalSince($0) < 120 })
        }
    }

    private static func antigravityHistory(account: Account, dataDir: String, limit: Int) -> [HistoryEntry] {
        let folder = URL(fileURLWithPath: dataDir).appending(path: "conversations")
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey])) ?? []
        return files.compactMap { url -> HistoryEntry? in
            guard ["pb", "db"].contains(url.pathExtension) else { return nil }
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            let date = values?.contentModificationDate
            let title = "Conversation of " + (date?.formatted(date: .abbreviated, time: .shortened) ?? "earlier")
            return HistoryEntry(id: url.deletingPathExtension().lastPathComponent, accountId: account.id, title: title, cwd: nil,
                                updatedAt: date, sizeBytes: Int64(values?.fileSize ?? 0))
        }.sorted { ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast) }.prefix(limit).map { $0 }
    }

    struct Settings {
        var mode: String?
        var model: String?
        var effort: String?
    }

    /// Claude Code: the last permission mode it switched to, and the model and effort of its last reply.
    static func claudeSettings(tail: [[String: Any]], head: [[String: Any]]) -> Settings {
        var settings = Settings()
        for line in (head + tail).reversed() {
            if settings.mode == nil, line["type"] as? String == "permission-mode", let mode = line["permissionMode"] as? String {
                settings.mode = mode == "default" ? "" : mode
            }
            if settings.model == nil, line["type"] as? String == "assistant",
               let model = (line["message"] as? [String: Any])?["model"] as? String, !model.hasPrefix("<") {
                settings.model = model
                if let effort = line["effort"] as? String { settings.effort = effort }
            }
            if settings.mode != nil, settings.model != nil { break }
        }
        if settings.mode == "" { settings.mode = nil }
        return settings
    }

    /// Codex: its turn context's approval policy and sandbox, model and reasoning effort.
    static func codexSettings(_ context: [String: Any]?) -> Settings {
        guard let context else { return Settings() }
        let approval = context["approval_policy"] as? String
        let sandbox = context["sandbox_policy"] as? String
            ?? (context["sandbox_policy"] as? [String: Any])?["type"] as? String ?? (context["sandbox_policy"] as? [String: Any])?["mode"] as? String
        var parts: [String] = []
        if let approval { parts.append("approval=\(approval)") }
        if let sandbox { parts.append("sandbox=\(sandbox)") }
        return Settings(mode: parts.isEmpty ? nil : "codex:" + parts.joined(separator: ";"),
                        model: context["model"] as? String, effort: context["effort"] as? String)
    }

    static func describe(_ settings: Settings) -> String? {
        var words: [String] = []
        if let mode = settings.mode {
            words.append(mode.hasPrefix("codex:")
                ? mode.dropFirst(6).replacingOccurrences(of: "approval=", with: "asks: ").replacingOccurrences(of: ";sandbox=", with: " · ")
                : mode)
        }
        if let model = settings.model { words.append(ModelNames.readable(model)) }
        if let effort = settings.effort { words.append("\(effort) effort") }
        return words.isEmpty ? nil : words.joined(separator: " · ")
    }

    /// A reader for a past conversation (read-only view in the app).
    static func reader(for account: Account, conversationId: String) -> TranscriptReader? {
        guard let dataDir = account.dataDir else { return nil }
        switch account.provider {
        case .claude:
            return claudeFile(dataDir: dataDir, sessionId: conversationId).map { ClaudeTranscript(url: $0) }
        case .codex:
            let sessions = URL(fileURLWithPath: dataDir).appending(path: "sessions")
            return rollouts(in: sessions, limit: 2000).first { $0.lastPathComponent.contains(conversationId) }
                .map { CodexTranscript(url: $0) }
        case .opencode:
            return OpenCodeTranscript(dbPath: "\(dataDir)/opencode.db", sessionId: conversationId)
        case .antigravity, .gemini, .shell, .other:
            return nil
        }
    }
}
