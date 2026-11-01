import Foundation

/// Turns a tool name and its input into the short lines the phone shows, for Claude Code's tools (and OpenCode's,
/// which use the same ideas with lower-case names).
enum ToolFormatter {
    static func category(for name: String) -> ToolCall.Category {
        let lower = name.lowercased()
        if lower.hasPrefix("mcp__") || lower.hasPrefix("mcp_") { return .mcp }
        switch lower {
        case "bash", "shell", "exec_command", "local_shell", "local_shell_call", "write_stdin", "bashoutput",
             "killshell", "killbash":
            return .shell
        case "read", "view_image", "notebookread", "ls", "list":
            return .read
        case "edit", "multiedit", "apply_patch", "patch", "str_replace_editor":
            return .edit
        case "write", "create":
            return .write
        case "grep", "glob", "search", "find", "codesearch", "toolsearch":
            return .search
        case "webfetch", "websearch", "web_search", "web_search_call", "fetch":
            return .web
        case "agent", "task":
            return .agent
        case "todowrite", "update_plan", "taskcreate", "taskupdate", "tasklist", "todoread", "todo":
            return .todo
        case "askuserquestion", "question":
            return .question
        case "exitplanmode", "enterplanmode", "plan":
            return .plan
        case "monitor":
            return .monitor
        case "workflow":
            return .workflow
        case "sendmessage", "listagents", "senduserfile", "pushnotification":
            return .message
        case "taskstop", "taskoutput", "schedulewakeup", "croncreate", "crondelete", "cronlist":
            return .task
        case "skill":
            return .skill
        case "notebookedit":
            return .notebook
        default:
            return .other
        }
    }

    static func string(_ input: [String: Any], _ keys: String...) -> String? {
        for key in keys {
            if let value = input[key] as? String, !value.isEmpty { return value }
        }
        return nil
    }

    static func shortPath(_ path: String, cwd: String?) -> String {
        if let cwd, path.hasPrefix(cwd + "/") { return String(path.dropFirst(cwd.count + 1)) }
        let home = HubPaths.home
        if path.hasPrefix(home + "/") { return "~/" + path.dropFirst(home.count + 1) }
        return path
    }

    /// Builds a tool call from its name and input; the result is filled in later.
    static func make(id: String, name: String, input: [String: Any], cwd: String?) -> ToolCall {
        let category = category(for: name)
        let inputText = JSONValue(foundation: input).prettyText
        let (clippedInput, _) = Clip.text(inputText, limit: Clip.inputLimit)
        var call = ToolCall(id: id, name: name, category: category, title: name, input: clippedInput, status: .pending)
        let lower = name.lowercased()

        switch category {
        case .shell:
            let command = string(input, "command", "cmd") ?? (input["command"] as? [String])?.joined(separator: " ") ?? ""
            call.subtitle = command
            let background = (input["run_in_background"] as? Bool) == true || (input["run_in_background"] as? String) == "true"
            if let description = string(input, "description") {
                call.title = description
            } else if lower == "bashoutput" || lower == "taskoutput" {
                call.title = "Read background output"
            } else if lower.hasPrefix("kill") {
                call.title = "Stop background command"
            } else {
                call.title = Clip.oneLine(command, limit: 80).nilIfEmpty ?? "Run a command"
            }
            if background { call.title = "\(call.title) (background)" }
        case .read:
            let path = string(input, "file_path", "filePath", "path", "notebook_path") ?? ""
            call.title = path.isEmpty ? "Read" : "Read \(URL(fileURLWithPath: path).lastPathComponent)"
            call.subtitle = path.isEmpty ? nil : shortPath(path, cwd: cwd)
            if let offset = input["offset"] as? Int, let limit = input["limit"] as? Int {
                call.subtitle = (call.subtitle ?? "") + " · lines \(offset)–\(offset + limit)"
            }
        case .edit, .write, .notebook:
            let path = string(input, "file_path", "filePath", "path", "notebook_path") ?? ""
            let file = URL(fileURLWithPath: path).lastPathComponent
            call.title = category == .write ? "Write \(file)" : "Edit \(file)"
            call.subtitle = path.isEmpty ? nil : shortPath(path, cwd: cwd)
            call.diff = Diffs.fromInput(name: lower, input: input, path: path)
        case .search:
            let pattern = string(input, "pattern", "query", "q") ?? ""
            let scope = string(input, "path", "glob", "include") ?? ""
            call.title = lower == "glob" ? "Find files \(pattern)" : (lower == "toolsearch" ? "Load tools" : "Search for \(pattern)")
            call.subtitle = scope.isEmpty ? nil : shortPath(scope, cwd: cwd)
        case .web:
            if let url = string(input, "url") {
                call.title = "Fetch \(URL(string: url)?.host ?? url)"
                call.subtitle = url
            } else {
                let query = string(input, "query", "q") ?? ""
                call.title = "Search the web"
                call.subtitle = query
            }
        case .agent:
            let type = string(input, "subagent_type", "subagentType", "agent") ?? "general-purpose"
            call.agentType = type
            let description = string(input, "description") ?? "Subagent"
            call.title = description
            call.subtitle = type == "fork" ? "Fork" : type
        case .todo:
            call.todos = Todos.from(input)
            call.title = lower == "update_plan" ? "Updated the plan" : "Updated the to-do list"
            if let subject = string(input, "subject"), lower == "taskcreate" { call.title = "Added task: \(subject)" }
            if lower == "taskupdate" {
                let status = string(input, "status") ?? "updated"
                call.title = "Task \(string(input, "taskId") ?? "") \(status)"
            }
        case .question:
            call.questions = Questions.from(input)
            call.title = call.questions?.first?.question ?? "Asked a question"
        case .plan:
            call.plan = string(input, "plan")
            call.title = lower == "enterplanmode" ? "Entered plan mode" : "Proposed a plan"
        case .monitor:
            call.title = string(input, "description") ?? "Monitor"
            call.subtitle = string(input, "command")
        case .workflow:
            call.title = "Workflow"
            if let script = string(input, "script"),
               let nameRange = script.range(of: #"name:\s*'([^']+)'"#, options: .regularExpression) {
                call.title = "Workflow " + script[nameRange].replacingOccurrences(of: "name:", with: "")
                    .trimmingCharacters(in: CharacterSet(charactersIn: " '"))
            } else if let named = string(input, "name") {
                call.title = "Workflow \(named)"
            }
        case .message:
            if lower == "sendmessage" {
                call.title = "Message to \(string(input, "to") ?? "an agent")"
                call.subtitle = string(input, "summary", "message")
            } else if lower == "listagents" {
                call.title = "Listed agents"
            } else {
                call.title = name
            }
        case .task:
            switch lower {
            case "taskstop": call.title = "Stopped a background task"
            case "schedulewakeup": call.title = "Scheduled a wake-up"
            default: call.title = name
            }
            call.subtitle = string(input, "task_id", "taskId", "reason")
        case .skill:
            call.title = "Used skill \(string(input, "skill", "name") ?? "")"
        case .mcp:
            let parts = name.components(separatedBy: "__").filter { !$0.isEmpty }
            let server = parts.count > 1 ? parts[1] : "MCP"
            let tool = parts.last ?? name
            call.title = "\(tool.replacingOccurrences(of: "_", with: " ")) (\(server))"
            call.subtitle = string(input, "query", "path", "url", "name")
        case .other:
            call.title = name
            call.subtitle = string(input, "description", "path", "file_path", "query", "url")
        }
        return call
    }

    /// Reads a tool result: the text and whether it reports a refusal.
    static func resultText(_ content: Any?) -> String {
        if let text = content as? String { return text }
        if let blocks = content as? [[String: Any]] {
            return blocks.compactMap { block -> String? in
                switch block["type"] as? String {
                case "text": return block["text"] as? String
                case "image": return "[image]"
                case "tool_reference": return (block["tool_name"] as? String).map { "[loaded \($0)]" }
                default: return nil
                }
            }.joined(separator: "\n")
        }
        return ""
    }

    static func isDenial(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.contains("the user doesn't want to proceed") || lower.contains("user rejected")
            || lower.contains("permission to use") && lower.contains("denied")
            || lower.hasPrefix("[request interrupted by user")
    }
}

/// Unified-diff lines from edit inputs and patches.
enum Diffs {
    static func fromInput(name: String, input: [String: Any], path: String) -> FileDiff? {
        switch name {
        case "edit", "str_replace_editor":
            guard let old = input["old_string"] as? String ?? input["oldString"] as? String,
                  let new = input["new_string"] as? String ?? input["newString"] as? String else { return nil }
            return simple(path: path, old: old, new: new)
        case "multiedit":
            guard let edits = input["edits"] as? [[String: Any]] else { return nil }
            var lines: [DiffLine] = []
            var additions = 0, deletions = 0
            for edit in edits {
                guard let old = edit["old_string"] as? String, let new = edit["new_string"] as? String,
                      let diff = simple(path: path, old: old, new: new) else { continue }
                lines.append(DiffLine(kind: .hunk, text: "@@"))
                lines += diff.lines
                additions += diff.additions
                deletions += diff.deletions
            }
            return FileDiff(path: path, lines: lines, additions: additions, deletions: deletions, isNewFile: false)
        case "write", "create":
            guard let content = input["content"] as? String else { return nil }
            let body = content.components(separatedBy: "\n")
            let shown = body.prefix(400).map { DiffLine(kind: .add, text: $0) }
            return FileDiff(path: path, lines: Array(shown), additions: body.count, deletions: 0, isNewFile: true)
        default:
            return nil
        }
    }

    static func simple(path: String, old: String, new: String) -> FileDiff? {
        let oldLines = old.components(separatedBy: "\n")
        let newLines = new.components(separatedBy: "\n")
        var lines: [DiffLine] = []
        // Trim the shared start and end so the change itself stands out.
        var prefix = 0
        while prefix < oldLines.count, prefix < newLines.count, oldLines[prefix] == newLines[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < oldLines.count - prefix, suffix < newLines.count - prefix,
              oldLines[oldLines.count - 1 - suffix] == newLines[newLines.count - 1 - suffix] { suffix += 1 }
        for line in oldLines.prefix(prefix).suffix(3) { lines.append(DiffLine(kind: .context, text: line)) }
        let removed = oldLines[prefix..<(oldLines.count - suffix)]
        let added = newLines[prefix..<(newLines.count - suffix)]
        lines += removed.map { DiffLine(kind: .remove, text: $0) }
        lines += added.map { DiffLine(kind: .add, text: $0) }
        for line in oldLines.suffix(suffix).prefix(3) { lines.append(DiffLine(kind: .context, text: line)) }
        return FileDiff(path: path, lines: Array(lines.prefix(600)), additions: added.count, deletions: removed.count,
                        isNewFile: false)
    }

    /// Claude's `structuredPatch` result: hunks with "+", "-" and " " prefixed lines.
    static func fromStructuredPatch(_ patch: [[String: Any]], path: String) -> FileDiff? {
        var lines: [DiffLine] = []
        var additions = 0, deletions = 0
        for hunk in patch {
            let oldStart = hunk["oldStart"] as? Int ?? 0
            let newStart = hunk["newStart"] as? Int ?? 0
            lines.append(DiffLine(kind: .hunk, text: "@@ -\(oldStart) +\(newStart) @@"))
            for raw in hunk["lines"] as? [String] ?? [] {
                if raw.hasPrefix("+") {
                    lines.append(DiffLine(kind: .add, text: String(raw.dropFirst())))
                    additions += 1
                } else if raw.hasPrefix("-") {
                    lines.append(DiffLine(kind: .remove, text: String(raw.dropFirst())))
                    deletions += 1
                } else {
                    lines.append(DiffLine(kind: .context, text: raw.hasPrefix(" ") ? String(raw.dropFirst()) : raw))
                }
            }
        }
        guard !lines.isEmpty else { return nil }
        return FileDiff(path: path, lines: Array(lines.prefix(800)), additions: additions, deletions: deletions,
                        isNewFile: false)
    }

    /// Codex's apply_patch format: "*** Begin Patch", "*** Update File: path", "@@", "+", "-", " ".
    static func fromApplyPatch(_ patch: String) -> [FileDiff] {
        var diffs: [FileDiff] = []
        var current: (path: String, lines: [DiffLine], add: Int, del: Int, new: Bool)?
        func flush() {
            if let c = current {
                diffs.append(FileDiff(path: c.path, lines: Array(c.lines.prefix(800)), additions: c.add, deletions: c.del,
                                      isNewFile: c.new))
            }
            current = nil
        }
        for raw in patch.components(separatedBy: "\n") {
            if raw.hasPrefix("*** Update File: ") {
                flush()
                current = (String(raw.dropFirst(17)), [], 0, 0, false)
            } else if raw.hasPrefix("*** Add File: ") {
                flush()
                current = (String(raw.dropFirst(14)), [], 0, 0, true)
            } else if raw.hasPrefix("*** Delete File: ") {
                flush()
                current = (String(raw.dropFirst(17)), [DiffLine(kind: .hunk, text: "File deleted")], 0, 0, false)
            } else if raw.hasPrefix("*** Move to: ") {
                current?.lines.append(DiffLine(kind: .hunk, text: "Moved to \(raw.dropFirst(13))"))
            } else if raw.hasPrefix("***") {
                continue
            } else if raw.hasPrefix("@@") {
                current?.lines.append(DiffLine(kind: .hunk, text: raw))
            } else if raw.hasPrefix("+") {
                current?.lines.append(DiffLine(kind: .add, text: String(raw.dropFirst())))
                current?.add += 1
            } else if raw.hasPrefix("-") {
                current?.lines.append(DiffLine(kind: .remove, text: String(raw.dropFirst())))
                current?.del += 1
            } else if current != nil {
                current?.lines.append(DiffLine(kind: .context, text: raw.hasPrefix(" ") ? String(raw.dropFirst()) : raw))
            }
        }
        flush()
        return diffs
    }
}

enum Todos {
    static func from(_ input: [String: Any]) -> [TodoItem]? {
        if let todos = input["todos"] as? [[String: Any]] {
            return todos.compactMap { todo in
                guard let content = todo["content"] as? String ?? todo["subject"] as? String else { return nil }
                return TodoItem(content: content, status: status(todo["status"]))
            }
        }
        if let plan = input["plan"] as? [[String: Any]] {
            return plan.compactMap { step in
                guard let text = step["step"] as? String else { return nil }
                return TodoItem(content: text, status: status(step["status"]))
            }
        }
        return nil
    }

    static func status(_ value: Any?) -> TodoItem.Status {
        switch (value as? String)?.lowercased() {
        case "completed", "done": .completed
        case "in_progress", "in-progress", "inprogress", "active": .inProgress
        default: .pending
        }
    }
}

enum Questions {
    static func from(_ input: [String: Any]) -> [QuestionSpec]? {
        guard let questions = input["questions"] as? [[String: Any]] else { return nil }
        return questions.compactMap { question in
            guard let text = question["question"] as? String else { return nil }
            let options = (question["options"] as? [[String: Any]] ?? []).compactMap { option -> QuestionOption? in
                guard let label = option["label"] as? String else { return nil }
                return QuestionOption(label: label, description: option["description"] as? String)
            }
            return QuestionSpec(question: text, header: question["header"] as? String, options: options,
                                multiSelect: question["multiSelect"] as? Bool ?? false)
        }
    }
}
