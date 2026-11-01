import Foundation

/// Reads a Claude Code conversation file (<config>/projects/<folder>/<session>.jsonl) into the timeline, and follows
/// its background work: shells, subagents (<session>/subagents/agent-<id>.jsonl), monitors, workflows.
final class ClaudeTranscript: TranscriptReader {
    let url: URL
    private var tail: JSONLTail
    let buffer = TimelineBuffer()
    private(set) var info = TranscriptInfo()
    private var taskMap: [String: BackgroundTask] = [:]
    private var taskOrder: [String] = []
    private var fullTools: [String: ToolCall] = [:]
    private var cwd: String?
    private var firstPrompt: String?
    private var tasksDir: String?
    private var subagents: [String: ClaudeTranscript] = [:]
    private let metaURL: URL?
    private var lastCommandItem: String?
    private var stopRequests: [String: String] = [:]

    init(url: URL, metaURL: URL? = nil) {
        self.url = url
        self.metaURL = metaURL
        tail = JSONLTail(url: url)
        info.agentSessionId = url.deletingPathExtension().lastPathComponent
    }

    var tasks: [BackgroundTask] { taskOrder.compactMap { taskMap[$0] } }

    /// <projects>/<folder>/<session>/ holds subagents/ and tool results.
    private var sessionDir: URL { url.deletingPathExtension() }
    private var subagentsDir: URL { sessionDir.appending(path: "subagents") }

    var subagentFinished: Bool {
        guard let metaURL, let data = try? Data(contentsOf: metaURL),
              let meta = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return meta["finished"] as? Bool ?? false
    }

    func poll() -> Bool {
        var changed = false
        switch tail.read() {
        case .none:
            break
        case .reset:
            buffer.reset()
            taskMap.removeAll()
            taskOrder.removeAll()
            fullTools.removeAll()
            changed = true
            if case .lines(let lines) = tail.read() { lines.forEach(process) }
        case .lines(let lines):
            lines.forEach(process)
            changed = true
        }
        if refreshAgentTasks() { changed = true }
        if info.title == nil, let firstPrompt { info.title = Clip.oneLine(firstPrompt, limit: 80) }
        return changed
    }

    func fullTool(_ id: String) -> ToolCall? { fullTools[id] }

    func subagentReader(_ agentId: String) -> TranscriptReader? {
        if let reader = subagents[agentId] { return reader }
        let file = subagentsDir.appending(path: "agent-\(agentId).jsonl")
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let reader = ClaudeTranscript(url: file, metaURL: subagentsDir.appending(path: "agent-\(agentId).meta.json"))
        subagents[agentId] = reader
        return reader
    }

    // MARK: Lines

    private func process(_ line: [String: Any]) {
        let type = line["type"] as? String
        let stamp = Stamp.parse(line["timestamp"])
        if let value = line["cwd"] as? String { cwd = value }
        if let branch = line["gitBranch"] as? String, !branch.isEmpty, branch != "HEAD" { info.gitBranch = branch }
        if let stamp, type == "user" || type == "assistant" { info.lastActivity = stamp }
        switch type {
        case "user": processUser(line, stamp)
        case "assistant": processAssistant(line, stamp)
        case "system": processSystem(line, stamp)
        case "ai-title": info.title = (line["aiTitle"] as? String)?.nilIfEmpty ?? info.title
        case "custom-title": info.title = (line["customTitle"] as? String)?.nilIfEmpty ?? info.title
        case "summary": if info.title == nil { info.title = line["summary"] as? String }
        case "permission-mode": info.permissionMode = line["permissionMode"] as? String
        case "attachment": processAttachment(line, stamp)
        default: break
        }
    }

    private func processUser(_ line: [String: Any], _ stamp: Date?) {
        let uuid = line["uuid"] as? String ?? UUID().uuidString
        let isMeta = line["isMeta"] as? Bool ?? false
        guard let message = line["message"] as? [String: Any] else { return }
        if let text = message["content"] as? String {
            userText(text, id: uuid, stamp: stamp, isMeta: isMeta, images: 0)
            return
        }
        guard let blocks = message["content"] as? [[String: Any]] else { return }
        var texts: [String] = []
        var images = 0
        for block in blocks {
            switch block["type"] as? String {
            case "text": texts.append(block["text"] as? String ?? "")
            case "image": images += 1
            case "tool_result": toolResult(block, line: line)
            default: break
            }
        }
        if !texts.isEmpty || images > 0 {
            userText(texts.joined(separator: "\n"), id: uuid, stamp: stamp, isMeta: isMeta, images: images)
        }
    }

    private func userText(_ raw: String, id: String, stamp: Date?, isMeta: Bool, images: Int) {
        if raw.contains("<task-notification>") {
            taskNotification(raw, id: id, stamp: stamp)
            return
        }
        if raw.contains("<command-name>") {
            let name = Tags.value("command-name", in: raw) ?? ""
            let args = Tags.value("command-args", in: raw) ?? ""
            let text = args.isEmpty ? name : "\(name) \(args)"
            buffer.upsert(TimelineItem(id: id, kind: .command, timestamp: stamp, text: text))
            lastCommandItem = id
            return
        }
        if raw.contains("<local-command-stdout>") || raw.contains("<local-command-stderr>") {
            let output = (Tags.value("local-command-stdout", in: raw) ?? "") + (Tags.value("local-command-stderr", in: raw) ?? "")
            let clean = ANSIStrip.strip(output).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty else { return }
            if let lastCommandItem, buffer.contains(lastCommandItem) {
                buffer.update(lastCommandItem) { item in
                    item.text = (item.text ?? "") + "\n" + clean
                }
            } else {
                buffer.upsert(TimelineItem(id: id, kind: .command, timestamp: stamp, text: clean))
            }
            return
        }
        if raw.contains("<bash-input>") {
            let command = Tags.value("bash-input", in: raw) ?? ""
            buffer.upsert(TimelineItem(id: id, kind: .command, timestamp: stamp, text: "! \(command)"))
            lastCommandItem = id
            return
        }
        if raw.contains("<bash-stdout>") || raw.contains("<bash-stderr>") {
            let output = [Tags.value("bash-stdout", in: raw), Tags.value("bash-stderr", in: raw)]
                .compactMap { $0 }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if let lastCommandItem, !output.isEmpty {
                buffer.update(lastCommandItem) { $0.text = ($0.text ?? "") + "\n" + output }
            }
            return
        }
        if isMeta { return }
        let text = Tags.removeBlocks("system-reminder", from: raw).trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("[Request interrupted by user") {
            buffer.upsert(TimelineItem(id: id, kind: .system, timestamp: stamp, text: "Interrupted", level: "notice"))
            return
        }
        guard !text.isEmpty || images > 0 else { return }
        if firstPrompt == nil, !text.isEmpty { firstPrompt = text }
        let attachments = images > 0 ? Array(repeating: "image", count: images) : nil
        buffer.upsert(TimelineItem(id: id, kind: .user, timestamp: stamp, text: text, attachments: attachments))
        if info.lastMessage == nil { info.lastMessage = Clip.oneLine(text) }
    }

    private func processAssistant(_ line: [String: Any], _ stamp: Date?) {
        let uuid = line["uuid"] as? String ?? UUID().uuidString
        guard let message = line["message"] as? [String: Any] else { return }
        if let model = message["model"] as? String, !model.hasPrefix("<") { info.model = model }
        if let usage = message["usage"] as? [String: Any] {
            // What the last request sent: the context in use (the status line adds the window size).
            let tokens = ["input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"]
                .reduce(0) { $0 + ((usage[$1] as? NSNumber)?.intValue ?? 0) }
            if tokens > 0 { info.usage = SessionUsage(contextTokens: tokens, updatedAt: stamp) }
        }
        if let effort = line["effort"] as? String { info.effort = effort }
        if line["isApiErrorMessage"] as? Bool == true {
            let text = ToolFormatter.resultText(message["content"])
            buffer.upsert(TimelineItem(id: uuid, kind: .system, timestamp: stamp, text: text, level: "error"))
            return
        }
        guard let blocks = message["content"] as? [[String: Any]] else { return }
        for (position, block) in blocks.enumerated() {
            let itemId = "\(uuid)#\(position)"
            switch block["type"] as? String {
            case "text":
                let text = (block["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                buffer.upsert(TimelineItem(id: itemId, kind: .assistant, timestamp: stamp, text: text))
                info.lastMessage = Clip.oneLine(text)
            case "thinking":
                let text = (block["thinking"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                buffer.upsert(TimelineItem(id: itemId, kind: .thinking, timestamp: stamp, text: text))
            case "tool_use", "server_tool_use":
                guard let id = block["id"] as? String, let name = block["name"] as? String else { continue }
                let input = block["input"] as? [String: Any] ?? [:]
                var call = ToolFormatter.make(id: id, name: name, input: input, cwd: cwd)
                var full = call
                full.input = JSONValue(foundation: input).prettyText
                fullTools[id] = full
                if call.category == .task, name == "TaskStop", let taskId = input["task_id"] as? String ?? input["taskId"] as? String {
                    stopRequests[id] = taskId
                }
                if buffer.contains(id) {
                    buffer.update(id) { item in
                        // Keep a result that already arrived.
                        if let existing = item.tool, existing.status != .pending {
                            call.status = existing.status
                            call.output = existing.output
                            call.outputTruncated = existing.outputTruncated
                        }
                        item.tool = call
                    }
                } else {
                    buffer.upsert(TimelineItem(id: id, kind: .tool, timestamp: stamp, tool: call))
                }
            default:
                continue
            }
        }
    }

    private func toolResult(_ block: [String: Any], line: [String: Any]) {
        guard let toolId = block["tool_use_id"] as? String else { return }
        let isError = block["is_error"] as? Bool ?? false
        let text = ToolFormatter.resultText(block["content"])
        let structured = line["toolUseResult"] as? [String: Any]
        let (clipped, truncated) = Clip.text(text, limit: Clip.outputLimit)
        if var full = fullTools[toolId] {
            full.output = String(text.prefix(512_000))
            fullTools[toolId] = full
        }
        var registered: BackgroundTask?
        buffer.update(toolId) { item in
            guard var tool = item.tool else { return }
            tool.output = clipped
            tool.outputTruncated = truncated
            tool.status = isError ? (ToolFormatter.isDenial(text) ? .denied : .failed) : .done
            if let structured {
                if let patch = structured["structuredPatch"] as? [[String: Any]],
                   let diff = Diffs.fromStructuredPatch(patch, path: tool.diff?.path ?? (structured["filePath"] as? String ?? "")) {
                    if structured["type"] as? String != "create" { tool.diff = diff }
                }
                if structured["interrupted"] as? Bool == true { tool.status = .failed }
                if let duration = structured["totalDurationMs"] as? Int ?? structured["durationMs"] as? Int {
                    tool.durationMs = duration
                }
                switch tool.category {
                case .shell:
                    if let taskId = structured["backgroundTaskId"] as? String {
                        tool.taskId = taskId
                        tool.status = .background
                        tool.outputFile = Self.outputPath(in: text)
                        registered = BackgroundTask(id: taskId, kind: .shell, title: tool.title.replacingOccurrences(of: " (background)", with: ""),
                                                    detail: tool.subtitle, status: .running, outputFile: tool.outputFile,
                                                    toolUseId: toolId, startedAt: item.timestamp)
                    }
                case .agent:
                    let agentId = structured["agentId"] as? String ?? Self.agentId(in: text)
                    tool.agentId = agentId
                    let async = structured["status"] as? String == "async_launched" || structured["isAsync"] as? Bool == true
                    if async { tool.status = .background }
                    if let agentId {
                        let kind: BackgroundTask.Kind = tool.agentType == "fork" ? .fork : .agent
                        registered = BackgroundTask(id: agentId, kind: kind, title: tool.title, detail: tool.agentType,
                                                    status: async ? .running : (isError ? .failed : .completed),
                                                    agentId: agentId, toolUseId: toolId, startedAt: item.timestamp)
                    }
                case .monitor:
                    if let taskId = structured["taskId"] as? String {
                        tool.taskId = taskId
                        tool.status = .background
                        tool.outputFile = Self.outputPath(in: text) ?? taskPath(taskId)
                        registered = BackgroundTask(id: taskId, kind: .monitor, title: tool.title, detail: tool.subtitle,
                                                    status: .running, outputFile: tool.outputFile, toolUseId: toolId,
                                                    startedAt: item.timestamp)
                    }
                case .workflow:
                    if let taskId = structured["taskId"] as? String {
                        tool.taskId = taskId
                        tool.status = .background
                        if let name = structured["workflowName"] as? String { tool.title = "Workflow \(name)" }
                        tool.subtitle = structured["summary"] as? String ?? tool.subtitle
                        registered = BackgroundTask(id: taskId, kind: .workflow, title: tool.title, detail: tool.subtitle,
                                                    status: .running, toolUseId: toolId, startedAt: item.timestamp)
                    }
                default:
                    break
                }
            } else if tool.category == .agent, let agentId = Self.agentId(in: text) {
                tool.agentId = agentId
            }
            item.tool = tool
        }
        if let task = registered { upsertTask(task) }
        if let taskId = stopRequests[toolId], !isError, var task = taskMap[taskId] {
            task.status = .stopped
            upsertTask(task)
        }
    }

    private func processSystem(_ line: [String: Any], _ stamp: Date?) {
        let id = line["uuid"] as? String ?? UUID().uuidString
        let content = line["content"] as? String
        switch line["subtype"] as? String {
        case "compact_boundary":
            buffer.upsert(TimelineItem(id: id, kind: .system, timestamp: stamp, text: "Conversation compacted", level: "info"))
        case "turn_duration":
            if let ms = line["durationMs"] as? Double ?? (line["durationMs"] as? Int).map(Double.init), ms >= 1000 {
                buffer.upsert(TimelineItem(id: id, kind: .system, timestamp: stamp, text: "Worked for \(Durations.text(ms / 1000))",
                                           level: "turn"))
            }
        case "api_error":
            buffer.upsert(TimelineItem(id: id, kind: .system, timestamp: stamp, text: content ?? "API error — retrying", level: "error"))
        case "away_summary":
            if let content { buffer.upsert(TimelineItem(id: id, kind: .system, timestamp: stamp, text: content, level: "recap")) }
        case "local_command":
            if let content, content.contains("<command-name>") {
                let name = Tags.value("command-name", in: content) ?? ""
                let args = Tags.value("command-args", in: content) ?? ""
                buffer.upsert(TimelineItem(id: id, kind: .command, timestamp: stamp, text: args.isEmpty ? name : "\(name) \(args)"))
                lastCommandItem = id
            }
        case "bridge_status":
            break
        default:
            if let content, !content.isEmpty {
                let level = line["level"] as? String ?? "info"
                buffer.upsert(TimelineItem(id: id, kind: .system, timestamp: stamp, text: content, level: level))
            }
        }
    }

    private func processAttachment(_ line: [String: Any], _ stamp: Date?) {
        guard let attachment = line["attachment"] as? [String: Any] else { return }
        let id = line["uuid"] as? String ?? UUID().uuidString
        switch attachment["type"] as? String {
        case "queued_command":
            guard let prompt = attachment["prompt"] as? String else { return }
            if prompt.contains("<task-notification>") {
                taskNotification(prompt, id: id, stamp: stamp)
            } else if (attachment["commandMode"] as? String ?? "prompt") == "prompt" {
                let text = Tags.removeBlocks("system-reminder", from: prompt).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return }
                buffer.upsert(TimelineItem(id: id, kind: .user, timestamp: stamp, text: text))
            }
        case "task_status":
            guard let taskId = attachment["taskId"] as? String else { return }
            let kind: BackgroundTask.Kind = {
                switch attachment["taskType"] as? String {
                case "local_bash": .shell
                case "local_agent", "remote_agent": .agent
                case "local_workflow": .workflow
                case "monitor", "local_monitor": .monitor
                default: .other
                }
            }()
            var task = taskMap[taskId] ?? BackgroundTask(id: taskId, kind: kind, title: attachment["description"] as? String ?? taskId,
                                                         status: .running, startedAt: stamp)
            task.status = Self.status(attachment["status"] as? String) ?? task.status
            task.outputFile = attachment["outputFilePath"] as? String ?? task.outputFile
            if let shell = attachment["shell"] as? [String: Any], let command = shell["command"] as? String {
                task.detail = command
            }
            if let path = task.outputFile { tasksDir = (path as NSString).deletingLastPathComponent }
            upsertTask(task)
        default:
            break
        }
    }

    // MARK: Background work

    private func taskNotification(_ text: String, id: String, stamp: Date?) {
        let taskId = Tags.value("task-id", in: text)
        let toolUseId = Tags.value("tool-use-id", in: text)
        let outputFile = Tags.value("output-file", in: text)
        let statusText = Tags.value("status", in: text)
        let summary = Tags.value("summary", in: text) ?? "A background task finished"
        let status = Self.status(statusText) ?? .completed
        if let outputFile { tasksDir = (outputFile as NSString).deletingLastPathComponent }
        let level = status == .failed ? "warning" : "info"
        buffer.upsert(TimelineItem(id: id, kind: .task, timestamp: stamp, text: summary, level: level))
        if let taskId {
            if var task = taskMap[taskId] {
                task.status = status
                task.summary = summary
                task.outputFile = task.outputFile ?? outputFile
                upsertTask(task)
            } else {
                upsertTask(BackgroundTask(id: taskId, kind: .other, title: summary, status: status, outputFile: outputFile,
                                          toolUseId: toolUseId, startedAt: stamp, summary: summary))
            }
        }
        if let toolUseId {
            buffer.update(toolUseId) { item in
                guard var tool = item.tool, tool.status == .background else { return }
                tool.status = status == .failed ? .failed : .done
                item.tool = tool
            }
        }
    }

    /// Subagents still running according to their transcript's meta file.
    private func refreshAgentTasks() -> Bool {
        var changed = false
        for id in taskOrder {
            guard var task = taskMap[id], task.status == .running, task.kind == .agent || task.kind == .fork,
                  let agentId = task.agentId else { continue }
            let meta = subagentsDir.appending(path: "agent-\(agentId).meta.json")
            guard let data = try? Data(contentsOf: meta),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["finished"] as? Bool == true else { continue }
            task.status = .completed
            taskMap[id] = task
            changed = true
            if let toolUseId = task.toolUseId {
                buffer.update(toolUseId) { item in
                    guard var tool = item.tool, tool.status == .background else { return }
                    tool.status = .done
                    item.tool = tool
                }
            }
        }
        return changed
    }

    private func upsertTask(_ task: BackgroundTask) {
        if taskMap[task.id] == nil { taskOrder.append(task.id) }
        var merged = task
        if let old = taskMap[task.id] {
            merged.startedAt = old.startedAt ?? task.startedAt
            merged.toolUseId = task.toolUseId ?? old.toolUseId
            merged.agentId = task.agentId ?? old.agentId
            merged.outputFile = task.outputFile ?? old.outputFile
            merged.detail = task.detail ?? old.detail
            if task.kind == .other { merged.kind = old.kind }
            if task.title == task.id { merged.title = old.title }
        }
        taskMap[task.id] = merged
    }

    private func taskPath(_ taskId: String) -> String? {
        if let tasksDir { return "\(tasksDir)/\(taskId).output" }
        guard let cwd, let session = info.agentSessionId else { return nil }
        let encoded = String(cwd.map { $0.isLetter || $0.isNumber ? $0 : "-" })
        return "/private/tmp/claude-\(getuid())/\(encoded)/\(session)/tasks/\(taskId).output"
    }

    static func outputPath(in text: String) -> String? {
        guard let range = text.range(of: #"Output is being written to: (\S+)"#, options: .regularExpression) else { return nil }
        var path = String(text[range]).replacingOccurrences(of: "Output is being written to: ", with: "")
        while path.hasSuffix(".") || path.hasSuffix(",") { path.removeLast() }
        return path
    }

    static func agentId(in text: String) -> String? {
        guard let range = text.range(of: #"agentId: ([A-Za-z0-9_-]+)"#, options: .regularExpression) else { return nil }
        return String(text[range]).replacingOccurrences(of: "agentId: ", with: "")
    }

    static func status(_ text: String?) -> BackgroundTask.Status? {
        switch text?.lowercased() {
        case "running", "pending", "started": .running
        case "completed", "done", "success", "finished": .completed
        case "failed", "error": .failed
        case "killed", "stopped", "cancelled", "canceled", "timeout", "expired": .stopped
        default: nil
        }
    }
}

/// Pulls values out of the pseudo-XML tags Claude Code puts in messages.
enum Tags {
    static func value(_ tag: String, in text: String) -> String? {
        guard let start = text.range(of: "<\(tag)>"), let end = text.range(of: "</\(tag)>", range: start.upperBound..<text.endIndex) else {
            return nil
        }
        return String(text[start.upperBound..<end.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func removeBlocks(_ tag: String, from text: String) -> String {
        var result = text
        while let start = result.range(of: "<\(tag)>"),
              let end = result.range(of: "</\(tag)>", range: start.upperBound..<result.endIndex) {
            result.removeSubrange(start.lowerBound..<end.upperBound)
        }
        return result
    }
}

enum Durations {
    static func text(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total)s" }
        let minutes = total / 60, rest = total % 60
        if minutes < 60 { return rest == 0 ? "\(minutes)m" : "\(minutes)m \(rest)s" }
        return "\(minutes / 60)h \(minutes % 60)m"
    }
}

/// Removes ANSI escape sequences.
enum ANSIStrip {
    private static let regex = try! NSRegularExpression(pattern: "\u{1B}\\[[0-9;?]*[ -/]*[@-~]|\u{1B}\\][^\u{07}\u{1B}]*(\u{07}|\u{1B}\\\\)|\u{1B}[@-Z\\\\-_]")

    static func strip(_ text: String) -> String {
        let ns = text as NSString
        return regex.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: ns.length), withTemplate: "")
    }
}
