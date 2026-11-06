import Darwin

/// The agent running in a session's pane, and whether macOS can still name the program file it runs.
///
/// An agent updated on disk while it runs keeps running its old program file, which the update deleted (an npm install
/// of Claude Code writes a new `claude.exe` every time, even for the same version). macOS's privacy checks name a
/// process by its program's path, so for such a process they fail before any permission is looked at (tccd logs
/// `proc_pidpath_audittoken() failed … No such process`), and the agent can't open anything a permission guards: a
/// screenshot dragged in from its floating thumbnail, the Desktop, Documents. Starting the agent again fixes it.
enum AgentProcess {
    /// The process group in front of the shell's terminal: the agent the session's script started (an interactive
    /// shell gives each command its own group, led by the command). Nil while the shell itself is in front.
    static func foreground(ofShell shell: Int32) -> Int32? {
        guard shell > 0 else { return nil }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(shell, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        let group = Int32(bitPattern: info.e_tpgid)
        return group > 0 && group != shell ? group : nil
    }

    /// Whether the program file `pid` runs was deleted or replaced after it started, so macOS can no longer name it
    /// (the same lookup macOS's privacy checks make). Nil when the process is gone.
    static func programReplaced(_ pid: Int32) -> Bool? {
        var path = [CChar](repeating: 0, count: Int(4 * MAXPATHLEN)) // PROC_PIDPATHINFO_MAXSIZE
        if proc_pidpath(pid, &path, UInt32(path.count)) > 0 { return false }
        let failure = errno
        guard RunningAgents.isAlive(pid) else { return nil }
        return failure == ESRCH || failure == ENOENT
    }
}
