import Foundation

/// Keeps each account's logo as its CLI draws it (`~/.agenthub/logos/<account>.json`).
///
/// - From real sessions: during a session's first minutes, its screen is read for a logo whenever the account has
///   none yet (or the saved one is two weeks old, so new CLI versions are picked up).
/// - By probing: an account never used through the hub is started once in the hub's own empty folder
///   (`~/.agenthub/probe`) in a hidden tmux session, its first screen is read, and it is closed again. No message is
///   ever sent. On that folder only, a "trust this folder?" question is answered yes; other prompts (an update
///   offer) are dismissed with Esc. Probing waits while a Pebble HOLD is up.
@MainActor
final class LogoService {
    static let folder = "\(HubPaths.root)/logos"
    static let probeFolder = HubPaths.probe

    private let tmux: Tmux
    private(set) var logos: [String: TerminalLogo] = [:]
    var onChange: ((String) -> Void)?
    private var probing = false
    private var probedThisRun: Set<String> = []

    init(tmux: Tmux) {
        self.tmux = tmux
        try? FileManager.default.createDirectory(atPath: Self.folder, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(atPath: Self.probeFolder, withIntermediateDirectories: true)
        load()
    }

    func needsLogo(_ accountId: String) -> Bool {
        guard let logo = logos[accountId] else { return true }
        return Date.now.timeIntervalSince(logo.capturedAt) > 14 * 86_400
    }

    /// Reads a live session's screen for its account's logo. Block or Braille art counts at once; a symbol logo only
    /// once the session has had time to draw its art, if it has any.
    func observe(sessionId: String, accountId: String, age: TimeInterval) async {
        guard needsLogo(accountId) else { return }
        let screen = await tmux.capture(sessions: [sessionId], escapes: true)[sessionId] ?? ""
        guard let logo = LogoExtractor.extract(screen), logo.source == "art" || age > 12 else { return }
        store(logo, for: accountId)
    }

    /// Probes, one at a time, every account with a command and no logo yet.
    func probeMissing(_ accounts: [Account]) async {
        guard !probing else { return }
        probing = true
        defer { probing = false }
        for account in accounts where account.provider != .shell && !account.command.isEmpty
            && needsLogo(account.id) && !probedThisRun.contains(account.id) {
            if await BusyHold.isActive() {
                Log.info("logos: the Mac is busy (hold-status.sh); probing later")
                return
            }
            probedThisRun.insert(account.id)
            await probe(account)
        }
    }

    private func probe(_ account: Account) async {
        let name = "ah-probe-" + String(account.id.map { $0.isLetter || $0.isNumber ? $0 : "-" })
        let script = """
        # Agent Hub: reads \(account.name)'s logo from its first screen, then closes. Nothing is sent to it.
        cd -- \(Shell.quote(Self.probeFolder)) || exit 1
        export AGENTHUB_PROBE=1
        \(account.command)
        """
        let path = "\(HubPaths.launch)/\(name).zsh"
        guard (try? script.write(toFile: path, atomically: true, encoding: .utf8)) != nil else { return }
        let shell = ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.hasSuffix("zsh") ? $0 : nil } ?? "/bin/zsh"
        do {
            try await tmux.newSession(name: name, directory: Self.probeFolder, command: "exec \(shell) -l -i \(Shell.quote(path))",
                                      columns: 120, rows: 40, environment: ["AGENTHUB_PROBE": "1"])
        } catch {
            Log.warn("logos: couldn't start \(account.id) to read its logo: \(error)")
            return
        }
        defer {
            Task { [tmux] in await tmux.kill(session: name) }
            try? FileManager.default.removeItem(atPath: path)
        }
        var promptsHandled = 0
        var symbol: (logo: TerminalLogo, attempt: Int)?
        for attempt in 0..<26 {
            try? await Task.sleep(for: .milliseconds(1500))
            guard let screen = await tmux.capture(sessions: [name], escapes: true)[name] else { continue }
            if let logo = LogoExtractor.extract(screen) {
                if logo.source == "art" {
                    store(logo, for: account.id)
                    return
                }
                // A symbol logo: give the CLI a few more seconds to draw art before settling for it.
                if let found = symbol {
                    if attempt - found.attempt >= 4 {
                        store(found.logo, for: account.id)
                        return
                    }
                } else {
                    symbol = (logo, attempt)
                }
            }
            guard let prompt = PaneReader.read(ANSIStrip.strip(screen)).prompt, promptsHandled < 4 else { continue }
            promptsHandled += 1
            let text = (prompt.question + " " + (prompt.context ?? "")).lowercased()
            if text.contains("trust"),
               let yes = prompt.options.first(where: { $0.label.lowercased().contains("trust") && !$0.isNegative })
                ?? prompt.options.first(where: { $0.label.lowercased().hasPrefix("yes") }) {
                let delta = yes.index - prompt.selectedIndex
                for _ in 0..<abs(delta) {
                    await tmux.sendKeys(session: name, keys: [delta > 0 ? "Down" : "Up"])
                    try? await Task.sleep(for: .milliseconds(60))
                }
                await tmux.sendKeys(session: name, keys: ["Enter"])
            } else {
                await tmux.sendKeys(session: name, keys: ["Escape"])
            }
        }
        if let found = symbol {
            store(found.logo, for: account.id)
            return
        }
        Log.info("logos: \(account.id) showed no logo on its first screen")
    }

    private func store(_ logo: TerminalLogo, for accountId: String) {
        let previous = logos[accountId]
        logos[accountId] = logo
        if let data = try? WireCoding.prettyEncoder.encode(logo) {
            try? data.write(to: URL(fileURLWithPath: "\(Self.folder)/\(accountId).json"), options: .atomic)
        }
        if previous?.mark != logo.mark || previous?.full != logo.full {
            Log.info("logos: read \(accountId)'s logo (\(logo.source), \(logo.mark.count) line\(logo.mark.count == 1 ? "" : "s"))")
            onChange?(accountId)
        }
    }

    private func load() {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: Self.folder)) ?? []
        for file in files where file.hasSuffix(".json") {
            guard let data = FileManager.default.contents(atPath: "\(Self.folder)/\(file)"),
                  let logo = try? WireCoding.decoder.decode(TerminalLogo.self, from: data) else { continue }
            logos[String(file.dropLast(5))] = logo
        }
    }
}

/// Whether Pebble's timed benchmark work has asked for quiet (PebbleRemote's hold-status script exits 3).
/// An optional script the hub asks before heavy background work (reading CLIs' logos and model lists): put an
/// executable at `~/.agenthub/hold-status.sh` that exits 3 while the Mac is busy with something more important (a long
/// benchmark, a recording), and the work waits. Without one, nothing waits.
enum BusyHold {
    static let script = "\(HubPaths.root)/hold-status.sh"

    static func isActive() async -> Bool {
        guard FileManager.default.isExecutableFile(atPath: script) else { return false }
        return await Shell.run(script, [], timeout: 10).status == 3
    }
}
