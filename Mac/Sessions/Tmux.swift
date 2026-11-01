import Foundation

/// One pane of an Agent Hub tmux session.
struct PaneInfo {
    var session: String
    var command: String
    var pid: Int32
    var dead: Bool
    var width: Int
    var height: Int
    var cursorX: Int
    var cursorY: Int
    var clients: Int
    var path: String
    var title: String
}

/// Agent Hub's own tmux server (socket "agenthub"), separate from any tmux the person runs, with its own config.
final class Tmux {
    static let socket = "agenthub"
    let path: String

    init?() {
        guard let path = Shell.which("tmux") else { return nil }
        self.path = path
        Tmux.writeConfig()
    }

    private func run(_ args: [String], input: Data? = nil, timeout: TimeInterval = 10) async -> ProcessResult {
        await Shell.run(path, ["-L", Tmux.socket, "-f", HubPaths.tmuxConf] + args, input: input,
                        environment: Tmux.environment, timeout: timeout)
    }

    /// tmux needs a UTF-8 locale and a sane PATH even when the hub was started by launchd.
    static let environment: [String: String] = {
        var env = ProcessInfo.processInfo.environment
        env["LANG"] = env["LANG"] ?? "en_US.UTF-8"
        env["LC_CTYPE"] = env["LC_CTYPE"] ?? "en_US.UTF-8"
        let extra = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        env["PATH"] = (env["PATH"].map { "\($0):" } ?? "") + extra
        env["SHELL"] = env["SHELL"] ?? "/bin/zsh"
        return env
    }()

    var attachCommand: String { "\(path) -L \(Tmux.socket) attach-session -t" }

    func newSession(name: String, directory: String, command: String, columns: Int, rows: Int,
                    environment: [String: String]) async throws {
        var args = ["new-session", "-d", "-s", name, "-x", "\(columns)", "-y", "\(rows)", "-c", directory]
        for (key, value) in environment.sorted(by: { $0.key < $1.key }) {
            args += ["-e", "\(key)=\(value)"]
        }
        args.append(command)
        let result = await run(args)
        guard result.ok else { throw WireError.failed("tmux couldn't start the session: \(result.err)") }
    }

    func setOption(session: String, key: String, value: String) async {
        _ = await run(["set-option", "-t", session, key, value])
    }

    func kill(session: String) async {
        _ = await run(["kill-session", "-t", session])
    }

    func hasSession(_ name: String) async -> Bool {
        await run(["has-session", "-t", name]).ok
    }

    func listPanes() async -> [PaneInfo] {
        let format = [
            "#{session_name}", "#{pane_current_command}", "#{pane_pid}", "#{pane_dead}", "#{pane_width}",
            "#{pane_height}", "#{cursor_x}", "#{cursor_y}", "#{session_attached}", "#{pane_current_path}",
            "#{pane_title}",
        ].joined(separator: "\u{1F}")
        let result = await run(["list-panes", "-a", "-F", format])
        guard result.ok else { return [] }
        return result.out.split(separator: "\n").compactMap { line in
            let f = line.split(separator: "\u{1F}", omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 11 else { return nil }
            return PaneInfo(session: f[0], command: f[1], pid: Int32(f[2]) ?? 0, dead: f[3] == "1",
                            width: Int(f[4]) ?? 80, height: Int(f[5]) ?? 24, cursorX: Int(f[6]) ?? 0,
                            cursorY: Int(f[7]) ?? 0, clients: Int(f[8]) ?? 0, path: f[9], title: f[10])
        }
    }

    /// Captures several panes in one tmux call. `escapes` keeps colour codes; `history` adds that many lines of
    /// scrollback above the visible screen.
    func capture(sessions: [String], escapes: Bool, history: Int = 0) async -> [String: String] {
        guard !sessions.isEmpty else { return [:] }
        let marker = "\u{1E}AGENTHUB-PANE\u{1E}"
        var args: [String] = []
        for (index, name) in sessions.enumerated() {
            if index > 0 { args.append(";") }
            args += ["display-message", "-p", "-t", name, "\(marker)\(name)", ";", "capture-pane", "-p", "-t", name]
            if escapes { args.append("-e") }
            if history > 0 { args += ["-S", "-\(history)"] }
        }
        let result = await run(args)
        var output: [String: String] = [:]
        let parts = result.out.components(separatedBy: marker)
        for part in parts.dropFirst() {
            guard let newline = part.firstIndex(of: "\n") else { continue }
            let name = String(part[..<newline])
            var body = String(part[part.index(after: newline)...])
            if body.hasSuffix("\n") { body.removeLast() }
            output[name] = body
        }
        // If one session vanished mid-call tmux stops there; capture the rest one by one.
        if !result.ok {
            for name in sessions where output[name] == nil {
                var args = ["capture-pane", "-p", "-t", name]
                if escapes { args.append("-e") }
                if history > 0 { args += ["-S", "-\(history)"] }
                let single = await run(args)
                if single.ok { output[name] = single.out }
            }
        }
        return output
    }

    func sendKeys(session: String, keys: [String]) async {
        guard !keys.isEmpty else { return }
        _ = await run(["send-keys", "-t", session] + keys)
    }

    func sendLiteral(session: String, text: String) async {
        _ = await run(["send-keys", "-t", session, "-l", "--", text])
    }

    /// Pastes text as one bracketed paste, so newlines don't submit early, then optionally presses Return.
    func paste(session: String, text: String, submit: Bool) async {
        if text.contains("\n") || text.count > 200 {
            let buffer = "ah-\(session)"
            _ = await run(["load-buffer", "-b", buffer, "-"], input: Data(text.utf8))
            _ = await run(["paste-buffer", "-p", "-d", "-b", buffer, "-t", session])
        } else if !text.isEmpty {
            await sendLiteral(session: session, text: text)
        }
        if submit {
            try? await Task.sleep(for: .milliseconds(text.isEmpty ? 0 : 140))
            await sendKeys(session: session, keys: ["Enter"])
        }
    }

    /// The hub's tmux settings: the person's own ~/.tmux.conf is never read for these sessions.
    static func writeConfig() {
        let config = """
        # Agent Hub's tmux server (socket "agenthub"). Written by the hub; edits are replaced at its next start.
        set -g default-terminal "xterm-256color"
        set -ga terminal-overrides ",xterm-256color:RGB,xterm*:Tc"
        set -g history-limit 50000
        set -g mouse on
        set -s escape-time 10
        set -g focus-events on
        set -s extended-keys on
        set -g set-titles on
        set -g set-titles-string "#{session_name} · #{@agenthub_title}"
        set -g allow-rename off
        set -g remain-on-exit off
        set -g window-size latest
        set -g aggressive-resize on
        set -g status on
        set -g status-position bottom
        set -g status-interval 5
        set -g status-style "bg=default,fg=colour245"
        set -g status-left "#[fg=colour111,bold] ◉ Agent Hub #[fg=colour245,nobold] #{@agenthub_title} "
        set -g status-left-length 120
        set -g status-right "#[fg=colour245]#{session_name}  %H:%M "
        set -g status-right-length 40
        set -g window-status-format ""
        set -g window-status-current-format ""
        set -g message-style "bg=colour236,fg=colour255"
        """
        try? config.write(toFile: HubPaths.tmuxConf, atomically: true, encoding: .utf8)
    }
}
