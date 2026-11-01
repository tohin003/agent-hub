import Foundation

/// Reads a Codex rollout file ($CODEX_HOME/sessions/YYYY/MM/DD/rollout-…-<id>.jsonl) into the timeline.
final class CodexTranscript: TranscriptReader {
    let url: URL
    private var tail: JSONLTail
    let buffer = TimelineBuffer()
    private(set) var info = TranscriptInfo()
    private var fullTools: [String: ToolCall] = [:]
    private var cwd: String?
    private var firstPrompt: String?
    private var lastUserText: String?
    private var counter = 0

    init(url: URL) {
        self.url = url
        tail = JSONLTail(url: url)
    }

    var tasks: [BackgroundTask] { [] }

    func poll() -> Bool {
        switch tail.read() {
        case .none:
            return false
        case .reset:
            buffer.reset()
            fullTools.removeAll()
            if case .lines(let lines) = tail.read() { lines.forEach(process) }
        case .lines(let lines):
            lines.forEach(process)
        }
        if info.title == nil, let firstPrompt { info.title = Clip.oneLine(firstPrompt, limit: 80) }
        return true
    }

    func fullTool(_ id: String) -> ToolCall? { fullTools[id] }

    private func nextId(_ prefix: String) -> String {
        counter += 1
        return "\(prefix)-\(counter)"
    }

    private func process(_ line: [String: Any]) {
        let stamp = Stamp.parse(line["timestamp"])
        let payload = line["payload"] as? [String: Any] ?? [:]
        switch line["type"] as? String {
        case "session_meta":
            info.agentSessionId = payload["id"] as? String ?? info.agentSessionId
            cwd = payload["cwd"] as? String ?? cwd
            if let git = payload["git"] as? [String: Any], let branch = git["branch"] as? String { info.gitBranch = branch }
        case "turn_context":
            info.model = payload["model"] as? String ?? info.model
            if let effort = payload["effort"] as? String { info.effort = effort }
            if let policy = payload["approval_policy"] as? String { info.permissionMode = policy }
            cwd = payload["cwd"] as? String ?? cwd
        case "response_item":
            responseItem(payload, stamp: stamp)
        case "event_msg":
            eventMessage(payload, stamp: stamp)
        default:
            break
        }
        if let stamp { info.lastActivity = stamp }
    }

    private func responseItem(_ item: [String: Any], stamp: Date?) {
        switch item["type"] as? String {
        case "message":
            let role = item["role"] as? String
            let text = Self.messageText(item["content"])
            guard !text.isEmpty else { return }
            if role == "assistant" {
                buffer.upsert(TimelineItem(id: item["id"] as? String ?? nextId("a"), kind: .assistant, timestamp: stamp, text: text))
                info.lastMessage = Clip.oneLine(text)
            } else if role == "user" {
                addUser(text, stamp: stamp)
            }
        case "reasoning":
            let summary = (item["summary"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined(separator: "\n\n")
            guard !summary.isEmpty else { return }
            buffer.upsert(TimelineItem(id: item["id"] as? String ?? nextId("r"), kind: .thinking, timestamp: stamp, text: summary))
        case "function_call":
            guard let callId = item["call_id"] as? String, let name = item["name"] as? String else { return }
            let arguments = item["arguments"] as? String ?? "{}"
            let input = (try? JSONSerialization.jsonObject(with: Data(arguments.utf8)) as? [String: Any]) ?? ["arguments": arguments]
            addTool(id: callId, name: name, input: input, stamp: stamp)
        case "custom_tool_call":
            guard let callId = item["call_id"] as? String, let name = item["name"] as? String else { return }
            let input = item["input"] as? String ?? ""
            if name == "apply_patch" {
                let diffs = Diffs.fromApplyPatch(input)
                let files = diffs.map { URL(fileURLWithPath: $0.path).lastPathComponent }
                var call = ToolCall(id: callId, name: name, category: .edit,
                                    title: files.isEmpty ? "Apply patch" : "Edit \(files.formatted())",
                                    subtitle: diffs.first.map { ToolFormatter.shortPath($0.path, cwd: cwd) },
                                    input: Clip.text(input, limit: Clip.inputLimit).0, status: .pending)
                call.diff = Self.merge(diffs)
                var full = call
                full.input = input
                fullTools[callId] = full
                buffer.upsert(TimelineItem(id: callId, kind: .tool, timestamp: stamp, tool: call))
            } else {
                addTool(id: callId, name: name, input: ["input": input], stamp: stamp)
            }
        case "function_call_output", "custom_tool_call_output":
            guard let callId = item["call_id"] as? String else { return }
            let output = Self.outputText(item["output"])
            finishTool(callId, output: output.text, exitCode: output.exitCode)
        case "local_shell_call":
            let callId = item["call_id"] as? String ?? nextId("sh")
            let action = item["action"] as? [String: Any] ?? [:]
            addTool(id: callId, name: "shell", input: action, stamp: stamp)
        case "web_search_call":
            let action = item["action"] as? [String: Any] ?? [:]
            let id = item["id"] as? String ?? nextId("web")
            var call = ToolFormatter.make(id: id, name: "web_search", input: action, cwd: cwd)
            call.status = .done
            buffer.upsert(TimelineItem(id: id, kind: .tool, timestamp: stamp, tool: call))
        default:
            break
        }
    }

    private func eventMessage(_ event: [String: Any], stamp: Date?) {
        switch event["type"] as? String {
        case "token_count":
            info.usage = Self.usage(event, stamp: stamp) ?? info.usage
        case "user_message":
            if let text = event["message"] as? String { addUser(text, stamp: stamp) }
        case "turn_aborted":
            buffer.upsert(TimelineItem(id: nextId("abort"), kind: .system, timestamp: stamp, text: "Interrupted", level: "notice"))
        case "error", "stream_error":
            let text = event["message"] as? String ?? "Error"
            buffer.upsert(TimelineItem(id: nextId("err"), kind: .system, timestamp: stamp, text: text, level: "error"))
        case "task_complete":
            if let started = event["duration_ms"] as? Double, started > 1000 {
                buffer.upsert(TimelineItem(id: nextId("turn"), kind: .system, timestamp: stamp,
                                           text: "Worked for \(Durations.text(started / 1000))", level: "turn"))
            }
        case "entered_review_mode":
            buffer.upsert(TimelineItem(id: nextId("review"), kind: .system, timestamp: stamp, text: "Review started", level: "info"))
        case "thread_name_updated":
            if let name = event["thread_name"] as? String ?? event["name"] as? String { info.title = name }
        case "exec_command_end":
            if let callId = event["call_id"] as? String {
                let output = event["aggregated_output"] as? String ?? event["formatted_output"] as? String
                    ?? [event["stdout"] as? String, event["stderr"] as? String].compactMap { $0 }.joined(separator: "\n")
                finishTool(callId, output: output, exitCode: event["exit_code"] as? Int)
            }
        default:
            break
        }
    }

    private func addUser(_ raw: String, stamp: Date?) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Codex records its own context (environment, AGENTS.md, instructions) as user messages.
        guard !text.isEmpty, !text.hasPrefix("<environment_context>"), !text.hasPrefix("<user_instructions>"),
              !text.hasPrefix("# AGENTS.md"), !text.hasPrefix("<permissions"), !text.hasPrefix("<INSTRUCTIONS>") else { return }
        if text == lastUserText { return }
        lastUserText = text
        if firstPrompt == nil { firstPrompt = text }
        buffer.upsert(TimelineItem(id: nextId("u"), kind: .user, timestamp: stamp, text: text))
    }

    private func addTool(id: String, name: String, input: [String: Any], stamp: Date?) {
        var call: ToolCall
        switch name {
        case "shell", "exec_command", "local_shell", "container.exec", "shell_command":
            let command: String = {
                if let words = input["command"] as? [String] {
                    if words.count >= 3, ["bash", "zsh", "sh", "/bin/bash", "/bin/zsh", "/bin/sh"].contains(words[0]),
                       words[1].hasPrefix("-") { return words[2] }
                    return words.joined(separator: " ")
                }
                return input["cmd"] as? String ?? input["command"] as? String ?? ""
            }()
            call = ToolFormatter.make(id: id, name: "Bash", input: ["command": command], cwd: cwd)
            call.name = name
        case "update_plan":
            call = ToolFormatter.make(id: id, name: "update_plan", input: input, cwd: cwd)
            if let explanation = input["explanation"] as? String, !explanation.isEmpty { call.subtitle = explanation }
        case "view_image":
            call = ToolFormatter.make(id: id, name: "Read", input: ["file_path": input["path"] as? String ?? ""], cwd: cwd)
            call.name = name
        case "write_stdin":
            call = ToolCall(id: id, name: name, category: .shell, title: "Typed into a running command",
                            subtitle: input["chars"] as? String, status: .pending)
        default:
            if name.contains("__") || name.contains(".") {
                call = ToolFormatter.make(id: id, name: "mcp__" + name.replacingOccurrences(of: ".", with: "__"), input: input, cwd: cwd)
                call.name = name
            } else {
                call = ToolFormatter.make(id: id, name: name, input: input, cwd: cwd)
            }
        }
        var full = call
        full.input = JSONValue(foundation: input).prettyText
        fullTools[id] = full
        buffer.upsert(TimelineItem(id: id, kind: .tool, timestamp: stamp, tool: call))
    }

    private func finishTool(_ id: String, output: String, exitCode: Int?) {
        if var full = fullTools[id] {
            full.output = String(output.prefix(512_000))
            fullTools[id] = full
        }
        let (clipped, truncated) = Clip.text(output, limit: Clip.outputLimit)
        buffer.update(id) { item in
            guard var tool = item.tool else { return }
            tool.output = clipped
            tool.outputTruncated = truncated
            tool.exitCode = exitCode
            let lower = output.lowercased()
            if lower.contains("rejected by user") || lower.contains("declined by user") {
                tool.status = .denied
            } else if let exitCode, exitCode != 0 {
                tool.status = .failed
            } else {
                tool.status = .done
            }
            item.tool = tool
        }
    }

    static func messageText(_ content: Any?) -> String {
        guard let parts = content as? [[String: Any]] else { return content as? String ?? "" }
        return parts.compactMap { part -> String? in
            switch part["type"] as? String {
            case "input_text", "output_text", "text": part["text"] as? String
            case "input_image": "[image]"
            default: nil
            }
        }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Codex outputs are text, or JSON text holding {output, metadata: {exit_code}}.
    static func outputText(_ value: Any?) -> (text: String, exitCode: Int?) {
        if let text = value as? String {
            if text.hasPrefix("{"), let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
               let output = object["output"] as? String {
                let meta = object["metadata"] as? [String: Any]
                return (output, meta?["exit_code"] as? Int)
            }
            if let range = text.range(of: #"(?m)^Exit code: (\d+)"#, options: .regularExpression) {
                let code = Int(text[range].replacingOccurrences(of: "Exit code: ", with: ""))
                return (text, code)
            }
            return (text, nil)
        }
        if let object = value as? [String: Any] {
            return (object["output"] as? String ?? JSONValue(foundation: object).prettyText, nil)
        }
        if let parts = value as? [[String: Any]] {
            return (parts.compactMap { $0["text"] as? String }.joined(separator: "\n"), nil)
        }
        return ("", nil)
    }

    static func merge(_ diffs: [FileDiff]) -> FileDiff? {
        guard let first = diffs.first else { return nil }
        guard diffs.count > 1 else { return first }
        var lines: [DiffLine] = []
        for diff in diffs {
            lines.append(DiffLine(kind: .hunk, text: diff.path))
            lines += diff.lines
        }
        return FileDiff(path: first.path, lines: Array(lines.prefix(1000)), additions: diffs.reduce(0) { $0 + $1.additions },
                        deletions: diffs.reduce(0) { $0 + $1.deletions }, isNewFile: false)
    }

    /// Codex's token count: the context the last turn used, the window, and the plan's limits.
    static func usage(_ event: [String: Any], stamp: Date?) -> SessionUsage? {
        var usage = SessionUsage(updatedAt: stamp)
        if let info = event["info"] as? [String: Any] {
            let last = info["last_token_usage"] as? [String: Any]
            usage.contextTokens = (last?["total_tokens"] as? NSNumber)?.intValue
            usage.contextWindow = (info["model_context_window"] as? NSNumber)?.intValue
            if let used = usage.contextTokens, let window = usage.contextWindow, window > 0 {
                usage.contextPercent = min(100, Double(used) / Double(window) * 100)
            }
        }
        if let limits = event["rate_limits"] as? [String: Any] {
            for key in ["primary", "secondary"] {
                guard let limit = limits[key] as? [String: Any], let percent = (limit["used_percent"] as? NSNumber)?.doubleValue
                else { continue }
                let minutes = (limit["window_minutes"] as? NSNumber)?.intValue ?? 0
                let resets = (limit["resets_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
                usage.limits.append(UsageLimit(name: windowName(minutes), percent: percent, resetsAt: resets))
            }
        }
        return usage.contextTokens == nil && usage.limits.isEmpty ? nil : usage
    }

    /// 300 minutes → "5-hour limit"; 10080 → "Weekly limit".
    static func windowName(_ minutes: Int) -> String {
        switch minutes {
        case 10_080: "Weekly limit"
        case 1_440: "Daily limit"
        case let m where m > 0 && m % 60 == 0: "\(m / 60)-hour limit"
        case let m where m > 0: "\(m)-minute limit"
        default: "Limit"
        }
    }
}
