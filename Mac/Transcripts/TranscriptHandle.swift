import Foundation

/// Owns one session's transcript reader on its own serial queue: finds the conversation file once the agent writes
/// it, reads what's new, and reports changes back to the main actor.
final class TranscriptHandle: @unchecked Sendable {
    struct PollResult {
        var changes: [TimelineItem] = []
        var reset = false
        var info: TranscriptInfo?
        var tasks: [BackgroundTask]?
        var located = false
    }

    let account: Account
    let cwd: String
    let startedAt: Date
    private let queue: DispatchQueue
    private var reader: TranscriptReader?
    private var lastLocateAttempt = Date.distantPast
    private var lastTasks: [BackgroundTask] = []
    private var lastInfo: TranscriptInfo?
    /// Claude: the conversation id passed with --session-id, or reported by the SessionStart hook.
    private var agentSessionId: String?
    private var explicitPath: String?
    private let resumeId: String?
    private(set) var locatedPath: String?

    init(account: Account, cwd: String, startedAt: Date, agentSessionId: String?, resumeId: String?, knownPath: String?) {
        self.account = account
        self.cwd = cwd
        self.startedAt = startedAt
        self.agentSessionId = agentSessionId
        self.resumeId = resumeId
        self.explicitPath = knownPath
        queue = DispatchQueue(label: "agenthub.transcript.\(UUID().uuidString.prefix(8))", qos: .utility)
    }

    var hasReader: Bool { queue.sync { reader != nil } }

    /// Switches to another conversation file (Claude after /clear or /resume, reported by the SessionStart hook).
    func follow(path: String, sessionId: String?) {
        queue.async {
            guard path != self.locatedPath else { return }
            self.explicitPath = path
            self.agentSessionId = sessionId ?? self.agentSessionId
            self.reader = nil
            self.lastLocateAttempt = .distantPast
        }
    }

    func poll(excluding: Set<String>) async -> PollResult {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: self.pollOnQueue(excluding: excluding))
            }
        }
    }

    private func pollOnQueue(excluding: Set<String>) -> PollResult {
        var result = PollResult()
        if reader == nil {
            guard Date.now.timeIntervalSince(lastLocateAttempt) > 1.5 else { return result }
            lastLocateAttempt = .now
            guard let found = locate(excluding: excluding) else { return result }
            reader = found
            result.located = true
            result.reset = true
        }
        guard let reader else { return result }
        let changed = reader.poll()
        if reader.buffer.resetPending {
            reader.buffer.resetPending = false
            result.reset = true
        }
        if result.reset {
            _ = reader.buffer.drainChanges()
            result.changes = reader.buffer.items
        } else if changed {
            result.changes = reader.buffer.drainChanges()
        }
        if reader.info != lastInfo || result.reset {
            lastInfo = reader.info
            result.info = reader.info
        }
        let tasks = reader.tasks
        if tasks != lastTasks || result.reset {
            lastTasks = tasks
            result.tasks = tasks
        }
        return result
    }

    private func locate(excluding: Set<String>) -> TranscriptReader? {
        guard let dataDir = account.dataDir else { return nil }
        switch account.provider {
        case .claude:
            if let explicitPath, FileManager.default.fileExists(atPath: explicitPath) {
                locatedPath = explicitPath
                return ClaudeTranscript(url: URL(fileURLWithPath: explicitPath))
            }
            guard let id = agentSessionId, let url = TranscriptLocator.claudeFile(dataDir: dataDir, sessionId: id) else { return nil }
            locatedPath = url.path
            return ClaudeTranscript(url: url)
        case .codex:
            if let explicitPath, FileManager.default.fileExists(atPath: explicitPath) {
                locatedPath = explicitPath
                return CodexTranscript(url: URL(fileURLWithPath: explicitPath))
            }
            guard let url = TranscriptLocator.codexRollout(dataDir: dataDir, cwd: cwd, since: startedAt, resumeId: resumeId,
                                                           excluding: excluding) else { return nil }
            locatedPath = url.path
            return CodexTranscript(url: url)
        case .opencode:
            let dbPath = "\(dataDir)/opencode.db"
            let id: String? = explicitPath.flatMap { $0.hasPrefix("opencode:") ? String($0.dropFirst(9)) : nil }
                ?? resumeId
                ?? OpenCodeTranscript.findSession(dbPath: dbPath, directory: cwd, since: startedAt,
                                                  excluding: Set(excluding.compactMap { $0.hasPrefix("opencode:") ? String($0.dropFirst(9)) : nil }))
            guard let id, let reader = OpenCodeTranscript(dbPath: dbPath, sessionId: id) else { return nil }
            locatedPath = "opencode:\(id)"
            return reader
        case .antigravity, .gemini, .shell, .other:
            return nil
        }
    }

    // MARK: Reads for requests (run on the reader's queue)

    func snapshot(tail: Int) -> (items: [TimelineItem], hasEarlier: Bool, tasks: [BackgroundTask]) {
        queue.sync {
            guard let reader else { return ([], false, []) }
            let (items, hasEarlier) = reader.buffer.tail(tail)
            return (items, hasEarlier, reader.tasks)
        }
    }

    func page(before id: String, limit: Int) -> (items: [TimelineItem], hasEarlier: Bool) {
        queue.sync { reader?.buffer.page(before: id, limit: limit) ?? ([], false) }
    }

    func fullTool(_ id: String, agentId: String?) -> ToolCall? {
        queue.sync {
            guard let reader else { return nil }
            if let agentId { return reader.subagentReader(agentId)?.fullTool(id) }
            return reader.fullTool(id)
        }
    }

    func subagent(_ agentId: String, since: Int) -> SubagentResult? {
        queue.sync {
            guard let sub = reader?.subagentReader(agentId) else { return nil }
            _ = sub.poll()
            _ = sub.buffer.drainChanges()
            let items = sub.buffer.changes(since: since)
            let title = reader?.tasks.first { $0.agentId == agentId }?.title
            return SubagentResult(items: since == 0 ? Array(items.suffix(400)) : items, version: sub.buffer.version,
                                  finished: sub.subagentFinished, title: title)
        }
    }

    var currentInfo: TranscriptInfo? { queue.sync { reader?.info } }
}
