import Foundation

/// Writes the small zsh script a session runs: it changes to the folder, starts the agent exactly as the person
/// would type it in their own shell (so `claude-w`, `opencode-p` and other shell functions work), and leaves an
/// interactive shell behind when the agent exits.
enum Launcher {
    struct Plan {
        var scriptPath: String
        var tmuxCommand: String
        /// For Claude: the conversation id passed with --session-id (or the one being resumed).
        var agentSessionId: String?
        var commandLine: String
    }

    static func plan(sessionId: String, account: Account, params: CreateSessionParams) throws -> Plan {
        var words: [String] = []
        var agentSessionId: String?
        let prompt = params.prompt?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        let model = params.model?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        let mode = params.mode?.nilIfEmpty
        let effort = params.effort?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        let fork = params.fork == true

        switch account.provider {
        case .claude:
            words.append(account.command)
            if let resume = params.resumeId {
                words += ["--resume", resume]
                if fork { words.append("--fork-session") } else { agentSessionId = resume }
            } else {
                let id = UUID().uuidString.lowercased()
                words += ["--session-id", id]
                agentSessionId = id
            }
            words += ["--settings", HubPaths.claudeSettings]
            if let mode { words += ["--permission-mode", mode] }
            if let model { words += ["--model", model] }
            if let effort { words += ["--effort", effort] }
            if let prompt { words.append(prompt) }
        case .codex:
            words.append(account.command)
            if let resume = params.resumeId {
                words += [fork ? "fork" : "resume"]
            }
            if let mode, mode.hasPrefix("codex:") {
                // A past conversation's own approval policy and sandbox.
                for part in mode.dropFirst(6).split(separator: ";") {
                    let pair = part.split(separator: "=", maxSplits: 1).map(String.init)
                    guard pair.count == 2 else { continue }
                    if pair[0] == "approval" { words += ["--ask-for-approval", pair[1]] }
                    if pair[0] == "sandbox" { words += ["--sandbox", pair[1]] }
                }
            } else {
                switch mode {
                case "workspace-write": words += ["--sandbox", "workspace-write", "--ask-for-approval", "on-request"]
                case "approve-for-me": words.append("--approve-for-me")
                case "read-only": words += ["--sandbox", "read-only"]
                case "yolo": words.append("--dangerously-bypass-approvals-and-sandbox")
                default: break
                }
            }
            if let model { words += ["--model", model] }
            if let effort { words += ["-c", "model_reasoning_effort=\"\(effort)\""] }
            if let resume = params.resumeId { words.append(resume) }
            if let prompt { words.append(prompt) }
        case .opencode:
            words.append(account.command)
            if let resume = params.resumeId {
                words += ["--session", resume]
                if fork { words.append("--fork") }
            }
            if let model { words += ["--model", model] }
            if let prompt { words += ["--prompt", prompt] }
        case .antigravity:
            words.append(account.command)
            if let resume = params.resumeId { words += ["--conversation", resume] }
            switch mode {
            case "accept-edits": words += ["--mode", "accept-edits"]
            case "plan": words += ["--mode", "plan"]
            case "skip": words.append("--dangerously-skip-permissions")
            default: break
            }
            if let model { words += ["--model", model] }
            if let prompt { words += ["--prompt-interactive", prompt] }
        case .gemini:
            words.append(account.command)
            if let resume = params.resumeId { words += ["--resume", resume] }
            if let mode { words += ["--approval-mode", mode] }
            if let model { words += ["--model", model] }
            if let prompt { words += ["--prompt-interactive", prompt] }
        case .shell, .other:
            if !account.command.isEmpty { words.append(account.command) }
        }

        // The account command may itself hold several words ("claude --plugin-dir x"): keep it unquoted so the
        // shell splits it; quote everything else.
        let commandLine: String = {
            guard let first = words.first else { return "" }
            let rest = words.dropFirst().map(Shell.quote).joined(separator: " ")
            return rest.isEmpty ? first : "\(first) \(rest)"
        }()

        let title = params.title ?? account.name
        let script = """
        # Agent Hub session \(sessionId): \(account.name) in \(params.cwd)
        # Started by the Agent Hub app. Runs in your interactive login shell, like typing it in Terminal.
        cd -- \(Shell.quote(params.cwd)) || { echo "Agent Hub: the folder is missing."; exec zsh -l; }
        export AGENTHUB_SESSION=\(Shell.quote(sessionId))
        export AGENTHUB_TITLE=\(Shell.quote(title))
        \(commandLine.isEmpty ? ": # a plain shell" : commandLine)
        exec zsh -l
        """
        let scriptPath = "\(HubPaths.launch)/\(sessionId).zsh"
        try script.write(toFile: scriptPath, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptPath)
        let shell = ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.hasSuffix("zsh") ? $0 : nil } ?? "/bin/zsh"
        let tmuxCommand = "exec \(shell) -l -i \(Shell.quote(scriptPath))"
        return Plan(scriptPath: scriptPath, tmuxCommand: tmuxCommand, agentSessionId: agentSessionId,
                    commandLine: commandLine)
    }

    /// Claude Code settings loaded only by sessions the hub starts (`--settings`): a SessionStart hook that tells
    /// the hub which conversation file the session writes (it changes after /clear or /resume), and a Notification
    /// hook. Nothing is printed, so nothing is added to Claude's context.
    static func installClaudeHooks() {
        let hook = """
        #!/bin/sh
        # Agent Hub: records Claude Code hook events for the session the hub started. Prints nothing.
        [ -n "$AGENTHUB_SESSION" ] || exit 0
        dir="$HOME/.agenthub/events"
        mkdir -p "$dir" 2>/dev/null
        { tr -d '\\n'; printf '\\n'; } >> "$dir/$AGENTHUB_SESSION.jsonl" 2>/dev/null
        exit 0
        """
        try? hook.write(toFile: HubPaths.hookScript, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: HubPaths.hookScript)
        // The status line: Claude Code hands it the session's context window, plan limits, model and effort. It
        // keeps a copy for the hub, then runs your own status line if you have one, so the terminal looks the same.
        let status = """
        #!/bin/sh
        # Agent Hub: keeps what Claude Code reports to its status line (context, limits, model, effort) for the
        # session the hub started, then shows your own status line, if you have one. Prints only what yours prints.
        input=$(cat)
        if [ -n "$AGENTHUB_SESSION" ]; then
          dir="$HOME/.agenthub/status"
          mkdir -p "$dir" 2>/dev/null
          printf '%s' "$input" > "$dir/$AGENTHUB_SESSION.json.tmp" 2>/dev/null &&
            mv -f "$dir/$AGENTHUB_SESSION.json.tmp" "$dir/$AGENTHUB_SESSION.json" 2>/dev/null
        fi
        for f in "$PWD/.claude/settings.local.json" "$PWD/.claude/settings.json" "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json"; do
          [ -f "$f" ] || continue
          cmd=$(/usr/bin/plutil -extract statusLine.command raw -o - "$f" 2>/dev/null) || continue
          [ -n "$cmd" ] || continue
          printf '%s' "$input" | /bin/sh -c "$cmd"
          exit 0
        done
        exit 0
        """
        let statusPath = "\(HubPaths.root)/statusline.sh"
        try? status.write(toFile: statusPath, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: statusPath)

        let command = HubPaths.hookScript
        let entry: [[String: Any]] = [["hooks": [["type": "command", "command": command, "timeout": 5]]]]
        let settings: [String: Any] = [
            "hooks": [
                "SessionStart": entry,
                "Notification": entry,
                "Stop": entry,
            ],
            "statusLine": ["type": "command", "command": statusPath, "padding": 0],
        ]
        if let data = try? JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: HubPaths.claudeSettings), options: .atomic)
        }
    }
}
