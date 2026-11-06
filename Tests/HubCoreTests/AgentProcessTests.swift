import Foundation
import Testing

/// An agent updated on disk while it runs: macOS can no longer name its program file (the lookup its privacy checks
/// make), so it can't open files a permission guards until it starts again. The hub notices, and restarts it the same
/// way it was running.
@Suite("Agents updated while they run")
struct AgentProcessTests {
    private func scratchFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "agenthub-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    @Test func programDeletedUnderARunningProcess() throws {
        let folder = try scratchFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let program = folder.appending(path: "sleep")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/sleep"), to: program)
        let process = Process()
        process.executableURL = program
        process.arguments = ["30"]
        try process.run()
        defer { if process.isRunning { process.terminate() } }
        let pid = process.processIdentifier

        #expect(AgentProcess.programReplaced(pid) == false)
        // What an update does to the file a running agent was started from.
        try FileManager.default.removeItem(at: program)
        #expect(AgentProcess.programReplaced(pid) == true)

        process.terminate()
        process.waitUntilExit()
        #expect(AgentProcess.programReplaced(pid) == nil)
    }

    @Test func foregroundCommandOfAnInteractiveShell() async throws {
        // Like a session's pane: an interactive shell on a terminal runs a script whose command it puts in front.
        let folder = try scratchFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let script = folder.appending(path: "session.zsh")
        try "/bin/sleep 30\n".write(to: script, atomically: true, encoding: .utf8)
        let terminal = Process()
        terminal.executableURL = URL(fileURLWithPath: "/usr/bin/script")
        terminal.arguments = ["-q", "/dev/null", "/bin/zsh", "-f", "-i", script.path]
        let input = Pipe() // kept open, so `script` doesn't stop at the end of its input
        terminal.standardInput = input
        terminal.standardOutput = FileHandle.nullDevice
        terminal.standardError = FileHandle.nullDevice
        try terminal.run()
        defer {
            if terminal.isRunning { terminal.terminate() }
            try? input.fileHandleForWriting.close()
        }

        var shell: Int32?
        var agent: Int32?
        for _ in 0..<40 where agent == nil {
            try await Task.sleep(for: .milliseconds(100))
            shell = shell ?? children(of: terminal.processIdentifier).first
            if let shell { agent = AgentProcess.foreground(ofShell: shell) }
        }
        let foreground = try #require(agent, "the shell never put its command in front")
        #expect(children(of: try #require(shell)).contains(foreground))
        #expect(AgentProcess.programReplaced(foreground) == false)
        #expect(AgentProcess.foreground(ofShell: ProcessInfo.processInfo.processIdentifier) == nil)
        Darwin.kill(foreground, SIGKILL)
    }

    @Test func claudeStartsAgainTheWayItRan() {
        let account = Account(id: "claude-p", name: "Claude · Personal", provider: .claude, command: "claude-p",
                              dataDir: nil, badge: "P", available: true, detail: nil)
        let settings = Shell.quote(HubPaths.claudeSettings)
        #expect(Launcher.restartLine(account: account, resumeId: "3c4fce56", attachedTo: nil, mode: "auto",
                                     model: "claude-opus-5-5", effort: "max")
                == "claude-p --resume 3c4fce56 --settings \(settings) --permission-mode auto --model claude-opus-5-5 --effort max")
        // Nothing known about the session yet: just the conversation and the hub's settings.
        #expect(Launcher.restartLine(account: account, resumeId: "3c4fce56", attachedTo: nil, mode: nil, model: "",
                                     effort: nil)
                == "claude-p --resume 3c4fce56 --settings \(settings)")
        // A background session is shown again, not resumed as a copy.
        #expect(Launcher.restartLine(account: account, resumeId: "3c4fce56", attachedTo: "a0703efc", mode: "auto",
                                     model: "claude-opus-5-5", effort: "max")
                == "claude-p attach a0703efc")
        let codex = Account(id: "codex", name: "Codex", provider: .codex, command: "codex", dataDir: nil, badge: nil,
                            available: true, detail: nil)
        #expect(Launcher.restartLine(account: codex, resumeId: "019a", attachedTo: nil, mode: "auto", model: "gpt",
                                     effort: "high")
                == "codex resume 019a")
    }

    private func children(of parent: Int32) -> [Int32] {
        var pids = [Int32](repeating: 0, count: 64)
        let count = proc_listchildpids(parent, &pids, Int32(pids.count * MemoryLayout<Int32>.size))
        return Array(pids.prefix(max(0, Int(count))))
    }
}
