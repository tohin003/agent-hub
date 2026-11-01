import Foundation
import SQLite3

/// A read-only connection to an OpenCode database (<data>/opencode/opencode.db).
final class SQLiteReader {
    private var db: OpaquePointer?

    init?(path: String) {
        guard FileManager.default.fileExists(atPath: path),
              sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            return nil
        }
        sqlite3_busy_timeout(db, 1500)
    }

    deinit { sqlite3_close(db) }

    /// Runs a query with text/integer bindings; each row is a column-name dictionary of String/Int64/Double.
    func query(_ sql: String, _ bindings: [Any] = []) -> [[String: Any]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (offset, value) in bindings.enumerated() {
            let index = Int32(offset + 1)
            switch value {
            case let text as String: sqlite3_bind_text(statement, index, text, -1, transient)
            case let number as Int: sqlite3_bind_int64(statement, index, Int64(number))
            case let number as Int64: sqlite3_bind_int64(statement, index, number)
            case let number as Double: sqlite3_bind_double(statement, index, number)
            default: sqlite3_bind_null(statement, index)
            }
        }
        var rows: [[String: Any]] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            var row: [String: Any] = [:]
            for column in 0..<sqlite3_column_count(statement) {
                let name = String(cString: sqlite3_column_name(statement, column))
                switch sqlite3_column_type(statement, column) {
                case SQLITE_INTEGER: row[name] = sqlite3_column_int64(statement, column)
                case SQLITE_FLOAT: row[name] = sqlite3_column_double(statement, column)
                case SQLITE_TEXT: row[name] = String(cString: sqlite3_column_text(statement, column))
                default: break
                }
            }
            rows.append(row)
        }
        return rows
    }
}

/// Reads one OpenCode session (messages and their parts) into the timeline. Subagents are child sessions.
final class OpenCodeTranscript: TranscriptReader {
    let dbPath: String
    let sessionId: String
    private let db: SQLiteReader
    let buffer = TimelineBuffer()
    private(set) var info = TranscriptInfo()
    private var fullTools: [String: ToolCall] = [:]
    private var lastPartUpdate: Int64 = 0
    private var lastMessageUpdate: Int64 = 0
    private var roles: [String: String] = [:]
    private var children: [String: OpenCodeTranscript] = [:]
    private var taskMap: [String: BackgroundTask] = [:]
    private var taskOrder: [String] = []
    private var cwd: String?

    init?(dbPath: String, sessionId: String) {
        guard let db = SQLiteReader(path: dbPath) else { return nil }
        self.db = db
        self.dbPath = dbPath
        self.sessionId = sessionId
        info.agentSessionId = sessionId
    }

    var tasks: [BackgroundTask] { taskOrder.compactMap { taskMap[$0] } }

    var subagentFinished: Bool {
        let rows = db.query("SELECT data FROM message WHERE session_id = ? ORDER BY time_created DESC LIMIT 1", [sessionId])
        guard let data = rows.first?["data"] as? String, let object = Self.json(data),
              let time = object["time"] as? [String: Any] else { return false }
        return time["completed"] != nil
    }

    func fullTool(_ id: String) -> ToolCall? { fullTools[id] }

    func subagentReader(_ agentId: String) -> TranscriptReader? {
        if let reader = children[agentId] { return reader }
        guard let reader = OpenCodeTranscript(dbPath: dbPath, sessionId: agentId) else { return nil }
        children[agentId] = reader
        return reader
    }

    func poll() -> Bool {
        var changed = false
        if let session = db.query("SELECT title, directory, time_updated FROM session WHERE id = ?", [sessionId]).first {
            let title = session["title"] as? String
            if let title, !title.isEmpty, !title.hasPrefix("New session"), title != info.title {
                info.title = title
                changed = true
            }
            cwd = session["directory"] as? String
        }
        for row in db.query("SELECT id, time_created, time_updated, data FROM message WHERE session_id = ? AND time_updated > ? ORDER BY time_created",
                            [sessionId, lastMessageUpdate]) {
            guard let id = row["id"] as? String, let data = row["data"] as? String, let object = Self.json(data) else { continue }
            roles[id] = object["role"] as? String
            if let model = object["modelID"] as? String { info.model = model }
            if object["role"] as? String == "assistant", let tokens = object["tokens"] as? [String: Any] {
                let cache = tokens["cache"] as? [String: Any]
                let used = [tokens["input"], tokens["output"], cache?["read"], cache?["write"]]
                    .reduce(0) { $0 + (($1 as? NSNumber)?.intValue ?? 0) }
                if used > 0 {
                    var usage = SessionUsage(contextTokens: used, updatedAt: Stamp.parse(row["time_updated"]))
                    if let provider = object["providerID"] as? String, let model = object["modelID"] as? String,
                       let window = OpenCodeModels.contextWindow(provider: provider, model: model) {
                        usage.contextWindow = window
                        usage.contextPercent = min(100, Double(used) / Double(window) * 100)
                    }
                    if let cost = (object["cost"] as? NSNumber)?.doubleValue { usage.costUSD = cost }
                    info.usage = usage
                }
            }
            if let updated = row["time_updated"] as? Int64 { lastMessageUpdate = max(lastMessageUpdate, updated) }
            if object["error"] != nil, let error = object["error"] as? [String: Any] {
                let message = (error["data"] as? [String: Any])?["message"] as? String ?? error["name"] as? String ?? "Error"
                buffer.upsert(TimelineItem(id: "\(id)-error", kind: .system, timestamp: Stamp.parse(row["time_created"]),
                                           text: message, level: "error"))
                changed = true
            }
        }
        let parts = db.query("SELECT id, message_id, time_created, time_updated, data FROM part WHERE session_id = ? AND time_updated >= ? ORDER BY message_id, id",
                             [sessionId, lastPartUpdate])
        for row in parts {
            guard let id = row["id"] as? String, let messageId = row["message_id"] as? String,
                  let data = row["data"] as? String, let part = Self.json(data) else { continue }
            if let updated = row["time_updated"] as? Int64 { lastPartUpdate = max(lastPartUpdate, updated) }
            let stamp = Stamp.parse(row["time_created"])
            info.lastActivity = stamp ?? info.lastActivity
            let role = roles[messageId] ?? "assistant"
            switch part["type"] as? String {
            case "text":
                guard part["synthetic"] as? Bool != true,
                      let text = (part["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { continue }
                buffer.upsert(TimelineItem(id: id, kind: role == "user" ? .user : .assistant, timestamp: stamp, text: text))
                if role != "user" { info.lastMessage = Clip.oneLine(text) }
                changed = true
            case "reasoning":
                guard let text = (part["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { continue }
                buffer.upsert(TimelineItem(id: id, kind: .thinking, timestamp: stamp, text: text))
                changed = true
            case "tool":
                toolPart(id: id, part: part, stamp: stamp)
                changed = true
            case "file":
                let name = part["filename"] as? String ?? "file"
                buffer.upsert(TimelineItem(id: id, kind: role == "user" ? .user : .system, timestamp: stamp, text: "📎 \(name)",
                                           level: "info"))
                changed = true
            case "compaction":
                buffer.upsert(TimelineItem(id: id, kind: .system, timestamp: stamp, text: "Conversation compacted", level: "info"))
                changed = true
            default:
                continue
            }
        }
        return changed
    }

    private func toolPart(id: String, part: [String: Any], stamp: Date?) {
        let callId = part["callID"] as? String ?? id
        let name = part["tool"] as? String ?? "tool"
        let state = part["state"] as? [String: Any] ?? [:]
        let input = state["input"] as? [String: Any] ?? [:]
        // OpenCode's tool names are lower-case versions of Claude Code's, with camelCase keys.
        var normalized = input
        if let path = input["filePath"] { normalized["file_path"] = path }
        if let old = input["oldString"] { normalized["old_string"] = old }
        if let new = input["newString"] { normalized["new_string"] = new }
        var call = ToolFormatter.make(id: callId, name: name, input: normalized, cwd: cwd)
        if let title = state["title"] as? String, !title.isEmpty, call.category != .edit, call.category != .write {
            call.title = title
        }
        let output = state["output"] as? String ?? (state["error"] as? String ?? "")
        let (clipped, truncated) = Clip.text(output, limit: Clip.outputLimit)
        call.output = output.isEmpty ? nil : clipped
        call.outputTruncated = truncated
        switch state["status"] as? String {
        case "completed": call.status = .done
        case "error": call.status = (output.lowercased().contains("rejected") ? .denied : .failed)
        case "running": call.status = .pending
        default: call.status = .pending
        }
        if let time = state["time"] as? [String: Any], let start = time["start"] as? Double, let end = time["end"] as? Double {
            call.durationMs = Int(end - start)
        }
        if call.category == .agent, let metadata = state["metadata"] as? [String: Any],
           let child = metadata["sessionId"] as? String ?? metadata["sessionID"] as? String {
            call.agentId = child
            let status: BackgroundTask.Status = call.status == .done ? .completed : (call.status == .failed ? .failed : .running)
            if taskMap[child] == nil { taskOrder.append(child) }
            taskMap[child] = BackgroundTask(id: child, kind: .agent, title: call.title, detail: call.agentType, status: status,
                                            agentId: child, toolUseId: callId, startedAt: stamp)
        }
        var full = call
        full.input = JSONValue(foundation: input).prettyText
        full.output = output
        fullTools[callId] = full
        buffer.upsert(TimelineItem(id: callId, kind: .tool, timestamp: stamp, tool: call))
    }

    static func json(_ text: String) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
    }

    /// The newest top-level session for a folder, created after `since` (used to find the session the hub started).
    static func findSession(dbPath: String, directory: String, since: Date, excluding: Set<String>) -> String? {
        guard let db = SQLiteReader(path: dbPath) else { return nil }
        let sinceMs = Int64((since.timeIntervalSince1970 - 10) * 1000)
        let resolved = (directory as NSString).resolvingSymlinksInPath
        let rows = db.query("SELECT id, directory FROM session WHERE parent_id IS NULL AND time_created >= ? ORDER BY time_created DESC LIMIT 20",
                            [sinceMs])
        for row in rows {
            guard let id = row["id"] as? String, !excluding.contains(id), let dir = row["directory"] as? String else { continue }
            if dir == directory || (dir as NSString).resolvingSymlinksInPath == resolved { return id }
        }
        return nil
    }
}

/// OpenCode's own copy of models.dev (`~/.cache/opencode/models.json`): each model's context window.
enum OpenCodeModels {
    nonisolated(unsafe) private static var windows: [String: Int]?
    nonisolated(unsafe) private static var loadedAt = Date.distantPast
    private static let lock = NSLock()

    static func contextWindow(provider: String, model: String) -> Int? {
        lock.lock()
        defer { lock.unlock() }
        if windows == nil || Date.now.timeIntervalSince(loadedAt) > 6 * 3600 {
            windows = load()
            loadedAt = .now
        }
        return windows?["\(provider)/\(model)"]
    }

    private static func load() -> [String: Int] {
        let path = NSString(string: "~/.cache/opencode/models.json").expandingTildeInPath
        guard let data = FileManager.default.contents(atPath: path),
              let providers = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        var windows: [String: Int] = [:]
        for (providerId, value) in providers {
            guard let provider = value as? [String: Any], let models = provider["models"] as? [String: Any] else { continue }
            for (modelId, model) in models {
                if let limit = (model as? [String: Any])?["limit"] as? [String: Any],
                   let context = (limit["context"] as? NSNumber)?.intValue {
                    windows["\(providerId)/\(modelId)"] = context
                }
            }
        }
        return windows
    }
}
