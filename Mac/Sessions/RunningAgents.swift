import Foundation

/// Claude Code sessions open on the Mac outside the hub, as Claude Code itself lists them (`claude agents --json`):
/// interactive ones in a terminal tab, and ones in its background service (`claude --bg`, its agent view). The hub
/// takes them over rather than starting a copy: a background session is attached as it runs (`claude attach`), a
/// terminal one moves into the hub once it's idle.
enum RunningAgents {
    struct Agent: Equatable, Sendable {
        enum Kind: Sendable { case interactive, background }
        var kind: Kind
        /// The agent's process (a background session may have none while it's parked).
        var pid: Int32?
        /// What `claude attach` takes (background sessions).
        var shortId: String?
        /// The conversation.
        var sessionId: String
        var cwd: String
        var name: String?
        /// Working on a turn ("busy"). A dialog waiting for an answer is "waiting" instead, not busy.
        var busy: Bool
        /// What a waiting session waits for ("input needed").
        var waitingFor: String? = nil
    }

    /// Where an interactive agent shows: its terminal device and the app drawing it ("Terminal", "iTerm", "tmux").
    struct Host: Equatable, Sendable {
        var tty: String?
        var app: String?
    }

    /// The account's open sessions, asked the way the person would ask (`claude-w agents --json`). Nil when the
    /// agent couldn't say (an older Claude Code without `agents`).
    static func list(account: Account) async -> [Agent]? {
        guard account.provider == .claude else { return nil }
        let folder = HubPaths.probe
        let line = "cd \(Shell.quote(folder)) && \(account.command) agents --json < /dev/null"
        let shell = ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.hasSuffix("zsh") ? $0 : nil } ?? "/bin/zsh"
        let result = await Shell.run(shell, ["-l", "-i", "-c", line], directory: folder, timeout: 25)
        return parse(result.out)
    }

    /// The JSON array `claude agents --json` prints, after anything the shell printed first.
    static func parse(_ output: String) -> [Agent]? {
        let lines = output.components(separatedBy: "\n")
        for (index, line) in lines.enumerated() where line.trimmingCharacters(in: .whitespaces).hasPrefix("[") {
            let text = lines[index...].joined(separator: "\n")
            guard let data = text.data(using: .utf8),
                  let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { continue }
            return rows.compactMap(agent)
        }
        return nil
    }

    private static func agent(_ row: [String: Any]) -> Agent? {
        guard let sessionId = row["sessionId"] as? String, !sessionId.isEmpty else { return nil }
        let kind: Agent.Kind
        switch row["kind"] as? String {
        case "background": kind = .background
        case "interactive": kind = .interactive
        default: return nil
        }
        let pid = (row["pid"] as? NSNumber).map { Int32(truncating: $0) }
        let shortId = (row["id"] as? String)?.nilIfEmpty
        // An interactive session is reached through its process, a background one through its id.
        if kind == .interactive, pid == nil { return nil }
        if kind == .background, shortId == nil { return nil }
        let status = row["status"] as? String
        return Agent(kind: kind, pid: pid, shortId: shortId, sessionId: sessionId, cwd: row["cwd"] as? String ?? "~",
                     name: (row["name"] as? String)?.nilIfEmpty, busy: status == "busy",
                     waitingFor: status == "waiting" ? (row["waitingFor"] as? String)?.nilIfEmpty ?? "an answer" : nil)
    }

    /// The terminal device and the app showing each process, from one `ps` listing: up the parent chain to the
    /// first app bundle (or a tmux server).
    static func hosts(of pids: [Int32]) async -> [Int32: Host] {
        guard !pids.isEmpty else { return [:] }
        let result = await Shell.run("/bin/ps", ["-axo", "pid=,ppid=,tty=,comm="], timeout: 10)
        return hosts(of: pids, listing: result.out)
    }

    static func hosts(of pids: [Int32], listing: String) -> [Int32: Host] {
        var parent: [Int32: Int32] = [:]
        var device: [Int32: String] = [:]
        var command: [Int32: String] = [:]
        for line in listing.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard parts.count == 4, let pid = Int32(parts[0]), let ppid = Int32(parts[1]) else { continue }
            parent[pid] = ppid
            device[pid] = String(parts[2])
            // The last column keeps the padding before it.
            command[pid] = parts[3].trimmingCharacters(in: .whitespaces)
        }
        var hosts: [Int32: Host] = [:]
        for pid in pids {
            let tty = device[pid].flatMap { $0 == "??" || $0.isEmpty ? nil : "/dev/" + $0 }
            var app: String?
            var current = parent[pid]
            for _ in 0..<16 {
                guard let ancestor = current, ancestor > 1, let path = command[ancestor] else { break }
                if (path as NSString).lastPathComponent == "tmux" {
                    app = "tmux"
                    break
                }
                if let bundle = path.components(separatedBy: "/").first(where: { $0.hasSuffix(".app") }) {
                    app = String(bundle.dropLast(4))
                    break
                }
                current = parent[ancestor]
            }
            hosts[pid] = Host(tty: tty, app: app)
        }
        return hosts
    }

    /// Busy or idle right now, from the record Claude Code keeps while a process runs (`<config>/sessions/<pid>.json`).
    static func isBusy(pid: Int32, dataDir: String?) -> Bool? {
        let folder = dataDir ?? NSString(string: "~/.claude").expandingTildeInPath
        guard let data = FileManager.default.contents(atPath: "\(folder)/sessions/\(pid).json"),
              let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let status = record["status"] as? String else { return nil }
        return status == "busy"
    }

    static func isAlive(_ pid: Int32) -> Bool {
        Darwin.kill(pid, 0) == 0 || errno == EPERM
    }
}
