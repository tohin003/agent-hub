import Foundation

/// An account's plan usage: Claude Code's own `/usage` (run on its own, without a conversation), or Codex's last
/// recorded limits.
@MainActor
final class AccountUsageReader {
    private var cache: [String: AccountUsage] = [:]
    private var running: [String: Task<AccountUsage, Error>] = [:]

    func usage(for account: Account, refresh: Bool) async throws -> AccountUsage {
        if !refresh, let cached = cache[account.id], Date.now.timeIntervalSince(cached.fetchedAt) < 180 { return cached }
        if let task = running[account.id] { return try await task.value }
        let task = Task<AccountUsage, Error> {
            switch account.provider {
            case .claude: try await Self.claudeUsage(account)
            case .codex: try Self.codexUsage(account)
            default: throw WireError.badRequest("\(account.name) doesn't report plan usage.")
            }
        }
        running[account.id] = task
        defer { running[account.id] = nil }
        let usage = try await task.value
        cache[account.id] = usage
        return usage
    }

    /// `claude -p /usage`: a local command, nothing is sent to the model and no conversation is kept.
    private static func claudeUsage(_ account: Account) async throws -> AccountUsage {
        let folder = LogoService.probeFolder
        let line = "cd \(Shell.quote(folder)) && \(account.command) -p /usage --no-session-persistence < /dev/null"
        let shell = ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.hasSuffix("zsh") ? $0 : nil } ?? "/bin/zsh"
        let result = await Shell.run(shell, ["-l", "-i", "-c", line], directory: folder, timeout: 60)
        let text = result.out
        let usage = ClaudeUsageText.parse(text, accountId: account.id)
        guard !usage.limits.isEmpty || !usage.notes.isEmpty else {
            Log.warn("usage: \(account.id)'s /usage gave nothing readable (exit \(result.status))")
            throw WireError.failed("\(account.name) didn't report its usage. Try again in a moment.")
        }
        return usage
    }

    /// Codex records its plan limits with every turn: the newest one across the account's conversations.
    private static func codexUsage(_ account: Account) throws -> AccountUsage {
        let home = account.dataDir ?? NSString(string: "~/.codex").expandingTildeInPath
        let root = URL(fileURLWithPath: home).appendingPathComponent("sessions")
        let files = (FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey])?
            .compactMap { $0 as? URL }.filter { $0.lastPathComponent.hasPrefix("rollout-") && $0.pathExtension == "jsonl" }) ?? []
        let newest = files.sorted {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return a > b
        }.prefix(12)
        for file in newest {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n").reversed() where line.contains("\"token_count\"") && line.contains("rate_limits") {
                guard let data = line.data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let payload = object["payload"] as? [String: Any],
                      let usage = CodexTranscript.usage(payload, stamp: Stamp.parse(object["timestamp"])), !usage.limits.isEmpty
                else { continue }
                // A window that has reset since Codex last ran starts again from nothing.
                let limits = usage.limits.map { limit -> UsageLimit in
                    guard let resets = limit.resetsAt, resets < .now else { return limit }
                    return UsageLimit(name: limit.name, percent: 0, resetsAt: nil, resetsText: "reset since Codex's last turn")
                }
                var notes: [String] = []
                if let limits = payload["rate_limits"] as? [String: Any], let plan = limits["plan_type"] as? String {
                    notes.append("Plan: \(plan.capitalized)")
                }
                if let stamp = usage.updatedAt {
                    notes.append("As of Codex's last turn, \(stamp.formatted(date: .abbreviated, time: .shortened)).")
                }
                return AccountUsage(accountId: account.id, limits: limits, notes: notes, sections: [],
                                    fetchedAt: usage.updatedAt ?? .now)
            }
        }
        throw WireError.failed("Codex hasn't recorded its limits yet. They appear after its first reply.")
    }
}

/// An account's slash commands, as the agent lists them: Claude Code names every command, skill and plugin command
/// in the first message of a non-interactive run (`-p /effort` runs locally: no conversation, nothing sent to the
/// model). Other agents don't list theirs, so their usual commands are offered.
@MainActor
final class AccountCommands {
    static let folder = "\(HubPaths.root)/commands"
    private var cache: [String: (commands: [SlashCommand], at: Date)] = [:]
    private var running: [String: Task<[SlashCommand]?, Never>] = [:]
    private let tmux: Tmux

    init(tmux: Tmux) {
        self.tmux = tmux
        try? FileManager.default.createDirectory(atPath: Self.folder, withIntermediateDirectories: true)
    }

    /// Reads the lists not read yet, one account at a time (at start, quietly).
    func probeMissing(_ accounts: [Account]) async {
        for account in accounts where account.provider == .claude && account.available
            && !FileManager.default.fileExists(atPath: path(account.id)) {
            if await BusyHold.isActive() { return }
            _ = await commands(for: account, refresh: false)
        }
    }

    func commands(for account: Account, refresh: Bool) async -> [SlashCommand] {
        guard account.provider == .claude else { return account.provider.slashCommands }
        if !refresh, let cached = cache[account.id], Date.now.timeIntervalSince(cached.at) < 3 * 86_400 { return cached.commands }
        if !refresh, let data = FileManager.default.contents(atPath: path(account.id)),
           let saved = try? WireCoding.decoder.decode([SlashCommand].self, from: data),
           let modified = (try? FileManager.default.attributesOfItem(atPath: path(account.id)))?[.modificationDate] as? Date,
           Date.now.timeIntervalSince(modified) < 3 * 86_400 {
            cache[account.id] = (saved, modified)
            return saved
        }
        let task = running[account.id] ?? Task { await Self.listClaude(account, tmux: tmux) }
        running[account.id] = task
        let listed = await task.value
        running[account.id] = nil
        guard let listed, !listed.isEmpty else { return cache[account.id]?.commands ?? account.provider.slashCommands }
        cache[account.id] = (listed, .now)
        if let data = try? WireCoding.prettyEncoder.encode(listed) {
            try? data.write(to: URL(fileURLWithPath: path(account.id)), options: .atomic)
        }
        return listed
    }

    private func path(_ accountId: String) -> String { "\(Self.folder)/\(accountId).json" }

    private static func listClaude(_ account: Account, tmux: Tmux) async -> [SlashCommand]? {
        async let named = namedClaude(account)
        let menu = await ProbeSession.run(account, tag: "commands", tmux: tmux) { name in
            await readSlashMenu(name, tmux: tmux)
        } ?? [:]
        let names = await named ?? []
        var byName: [String: SlashCommand] = [:]
        for command in names { byName[command.command] = command }
        for (command, description) in menu {
            let kind = byName[command]?.detail
            byName[command] = SlashCommand(command, description.isEmpty ? (kind ?? "") : description)
        }
        guard !byName.isEmpty else { return nil }
        Log.info("commands: \(account.id) has \(byName.count) slash commands (\(menu.count) from its menu)")
        return byName.values.sorted { $0.command < $1.command }
    }

    /// Claude Code's "/" menu: "  /branch      Create a branch of the current conversation", scrolled to the end.
    private static func readSlashMenu(_ session: String, tmux: Tmux) async -> [String: String]? {
        await tmux.sendLiteral(session: session, text: "/")
        try? await Task.sleep(for: .milliseconds(1200))
        var found: [String: String] = [:]
        var quiet = 0
        for step in 0..<220 {
            if step > 0 {
                await tmux.sendKeys(session: session, keys: ["Down"])
                try? await Task.sleep(for: .milliseconds(60))
                guard step % 3 == 0 else { continue }
            }
            let screen = await tmux.capture(sessions: [session], escapes: false)[session] ?? ""
            let before = found.count
            for (command, description) in PaneReader.slashMenu(screen) where (found[command] ?? "").count < description.count {
                found[command] = description
            }
            quiet = found.count == before ? quiet + 1 : 0
            if quiet >= 6 { break }
        }
        await tmux.sendKeys(session: session, keys: ["Escape"])
        await tmux.sendKeys(session: session, keys: ["C-u"])
        return found.isEmpty ? nil : found
    }

    private static func namedClaude(_ account: Account) async -> [SlashCommand]? {
        let folder = LogoService.probeFolder
        let line = "cd \(Shell.quote(folder)) && \(account.command) -p /effort --output-format stream-json --verbose "
            + "--no-session-persistence < /dev/null"
        let shell = ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.hasSuffix("zsh") ? $0 : nil } ?? "/bin/zsh"
        let result = await Shell.run(shell, ["-l", "-i", "-c", line], directory: folder, timeout: 60)
        for raw in result.out.split(separator: "\n") where raw.contains("\"subtype\":\"init\"") {
            guard let data = raw.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let names = json["slash_commands"] as? [String] else { continue }
            let skills = Set(json["skills"] as? [String] ?? [])
            var seen: Set<String> = []
            var commands: [SlashCommand] = []
            for name in names where !name.hasPrefix("_") && seen.insert(name).inserted {
                let kind = skills.contains(name) ? "Skill" : (name.contains(":") ? "Plugin" : "Command")
                commands.append(SlashCommand("/" + name, kind))
            }
            Log.info("commands: read \(account.id)'s \(commands.count) slash commands")
            return commands
        }
        Log.warn("commands: \(account.id) listed no slash commands (exit \(result.status))")
        return nil
    }
}

/// Each model's context window, as Claude Code reports it: learnt from the status line of any session that has
/// one, else asked once per model (`claude -p /context --model <id>`: local, nothing sent to the model). Kept in
/// `~/.agenthub/context-windows.json`.
@MainActor
final class ContextWindows {
    static let path = "\(HubPaths.root)/context-windows.json"
    private(set) var windows: [String: Int] = [:]
    private var asked: Set<String> = []
    /// Called when a window is learnt, so sessions can show it.
    var onLearned: (() -> Void)?

    init() {
        if let data = FileManager.default.contents(atPath: Self.path),
           let saved = try? JSONDecoder().decode([String: Int].self, from: data) {
            windows = saved
        }
    }

    func window(for model: String?) -> Int? { model.flatMap { windows[$0] } }

    func learn(model: String, window: Int) {
        guard windows[model] != window else { return }
        windows[model] = window
        if let data = try? JSONEncoder().encode(windows) {
            try? data.write(to: URL(fileURLWithPath: Self.path), options: .atomic)
        }
        Log.info("context: \(model) has a \(window)-token window")
        onLearned?()
    }

    /// Asks the account's Claude Code once (per hub run) for this model's window.
    func ask(_ account: Account, model: String) {
        guard account.provider == .claude, windows[model] == nil, asked.insert(model).inserted else { return }
        Task {
            let folder = LogoService.probeFolder
            let line = "cd \(Shell.quote(folder)) && \(account.command) -p /context --model \(Shell.quote(model)) "
                + "--output-format stream-json --verbose --no-session-persistence < /dev/null"
            let shell = ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.hasSuffix("zsh") ? $0 : nil } ?? "/bin/zsh"
            let result = await Shell.run(shell, ["-l", "-i", "-c", line], directory: folder, timeout: 60)
            for raw in result.out.split(separator: "\n") where raw.contains("\"type\":\"result\"") {
                guard let data = raw.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let text = json["result"] as? String, let window = ContextText.window(text) else { continue }
                learn(model: model, window: window)
                return
            }
            Log.warn("context: \(account.id) didn't report \(model)'s window (exit \(result.status))")
        }
    }
}

/// The models each account offers, read from the agent itself: Claude Code's `/model` and `/effort` pickers (in a
/// hidden window in the probe folder, nothing sent), Codex's own model cache. Kept in `~/.agenthub/models/`.
@MainActor
final class ModelCatalogs {
    static let folder = "\(HubPaths.root)/models"
    private let tmux: Tmux
    private var catalogs: [String: ModelCatalog] = [:]
    private var running: [String: Task<ModelCatalog?, Never>] = [:]

    init(tmux: Tmux) {
        self.tmux = tmux
        try? FileManager.default.createDirectory(atPath: Self.folder, withIntermediateDirectories: true)
        for file in (try? FileManager.default.contentsOfDirectory(atPath: Self.folder)) ?? [] where file.hasSuffix(".json") {
            if let data = FileManager.default.contents(atPath: "\(Self.folder)/\(file)"),
               let catalog = try? WireCoding.decoder.decode(ModelCatalog.self, from: data) {
                catalogs[catalog.accountId] = catalog
            }
        }
    }

    /// The list already read; Codex's is read from its cache file each time (it isn't kept here).
    func cached(_ account: Account) -> ModelCatalog? {
        if account.provider == .codex, let catalog = Self.codexCatalog(account) { return catalog }
        return catalogs[account.id]
    }

    func catalog(for account: Account, refresh: Bool) async throws -> ModelCatalog {
        if account.provider == .codex, let catalog = Self.codexCatalog(account) {
            catalogs[account.id] = catalog
            return catalog
        }
        guard account.provider == .claude else {
            throw WireError.badRequest("Choose \(account.name)'s model in its own picker: Show Keys › type /model.")
        }
        if !refresh, let catalog = catalogs[account.id], Date.now.timeIntervalSince(catalog.capturedAt) < 3 * 86_400 {
            return catalog
        }
        let task = running[account.id] ?? Task { await self.probeClaude(account) }
        running[account.id] = task
        let catalog = await task.value
        running[account.id] = nil
        if let catalog { return catalog }
        if let old = catalogs[account.id] { return old }
        throw WireError.failed("Couldn't read \(account.name)'s models. Try again in a moment.")
    }

    /// Reads the catalogs not read yet, one account at a time (at start, quietly).
    func probeMissing(_ accounts: [Account]) async {
        for account in accounts where account.provider == .claude && account.available && catalogs[account.id] == nil {
            if await BusyHold.isActive() { return }
            _ = try? await catalog(for: account, refresh: false)
        }
    }

    private func store(_ catalog: ModelCatalog) {
        catalogs[catalog.accountId] = catalog
        if let data = try? WireCoding.prettyEncoder.encode(catalog) {
            try? data.write(to: URL(fileURLWithPath: "\(Self.folder)/\(catalog.accountId).json"), options: .atomic)
        }
    }

    // MARK: Codex

    /// `<CODEX_HOME>/models_cache.json`: the models Codex lists, with their effort levels.
    static func codexCatalog(_ account: Account) -> ModelCatalog? {
        let home = account.dataDir ?? NSString(string: "~/.codex").expandingTildeInPath
        guard let data = FileManager.default.contents(atPath: "\(home)/models_cache.json"),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["models"] as? [[String: Any]] else { return nil }
        let listed = models.filter { ($0["visibility"] as? String ?? "list") == "list" }
            .sorted { (($0["priority"] as? NSNumber)?.intValue ?? 99) < (($1["priority"] as? NSNumber)?.intValue ?? 99) }
        var options: [ModelOption] = []
        var allLevels: [String] = []
        for model in listed {
            guard let slug = model["slug"] as? String else { continue }
            let levels = (model["supported_reasoning_levels"] as? [[String: Any]] ?? []).compactMap { $0["effort"] as? String }
            for level in levels where !allLevels.contains(level) { allLevels.append(level) }
            options.append(ModelOption(number: options.count + 1, label: model["display_name"] as? String ?? slug,
                                       detail: model["description"] as? String, slug: slug,
                                       effortLevels: levels, defaultEffort: model["default_reasoning_level"] as? String))
        }
        guard !options.isEmpty else { return nil }
        let fetched = (json["fetched_at"] as? String).flatMap { Stamp.parse($0) } ?? .now
        return ModelCatalog(accountId: account.id, options: options, effortLevels: allLevels, source: "cache", capturedAt: fetched)
    }

    // MARK: Claude Code

    private func probeClaude(_ account: Account) async -> ModelCatalog? {
        let catalog: ModelCatalog? = await ProbeSession.run(account, tag: "models", tmux: tmux) { name in
            let driver = PickerDriver(tmux: tmux, session: name)
            guard let options = await driver.readModelPicker() else {
                Log.warn("models: \(account.id) showed no model picker")
                return nil
            }
            await tmux.sendKeys(session: name, keys: ["Escape"])
            try? await Task.sleep(for: .milliseconds(800))
            let levels = await driver.readEffortLevels()
            await tmux.sendKeys(session: name, keys: ["Escape"])
            return ModelCatalog(accountId: account.id, options: options, effortLevels: levels, source: "picker", capturedAt: .now)
        }
        guard let catalog else { return nil }
        store(catalog)
        Log.info("models: read \(account.id)'s \(catalog.options.count) models and \(catalog.effortLevels.count) effort levels")
        return catalog
    }
}

extension Tmux {
    /// Reads a session's screen; again with its colours when a dialog there shows its choice only in colour.
    func reading(_ session: String) async -> PaneReader.Reading {
        let plain = await capture(sessions: [session], escapes: false)[session] ?? ""
        return await reading(session, plain: plain)
    }

    func reading(_ session: String, plain: String) async -> PaneReader.Reading {
        let first = PaneReader.read(plain)
        guard first.prompt == nil || first.prompt?.optional == true, PaneReader.wantsStyle(plain),
              let styled = await capture(sessions: [session], escapes: true)[session] else { return first }
        // Both readings from the one colour capture, so the text and its colours match.
        return PaneReader.read(PaneReader.cleanEscapes(styled), styled: styled)
    }
}

/// One of an account's CLIs started in a hidden window in the probe folder, ready for its input, for the hub to read
/// its menus. Nothing is sent to the model; the window closes afterwards.
@MainActor
enum ProbeSession {
    static func run<T>(_ account: Account, tag: String, tmux: Tmux, _ body: (String) async -> T?) async -> T? {
        let name = "ah-\(tag)-" + String(account.id.map { $0.isLetter || $0.isNumber ? $0 : "-" })
        let script = """
        # Agent Hub: reads \(account.name)'s menus, then closes. Nothing is sent to it.
        cd -- \(Shell.quote(LogoService.probeFolder)) || exit 1
        export AGENTHUB_PROBE=1
        \(account.command)
        """
        let path = "\(HubPaths.launch)/\(name).zsh"
        guard (try? script.write(toFile: path, atomically: true, encoding: .utf8)) != nil else { return nil }
        let shell = ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.hasSuffix("zsh") ? $0 : nil } ?? "/bin/zsh"
        do {
            try await tmux.newSession(name: name, directory: LogoService.probeFolder,
                                      command: "exec \(shell) -l -i \(Shell.quote(path))", columns: 140, rows: 50,
                                      environment: ["AGENTHUB_PROBE": "1"])
        } catch {
            Log.warn("probe: couldn't start \(account.id): \(error)")
            return nil
        }
        defer {
            Task { [tmux] in await tmux.kill(session: name) }
            try? FileManager.default.removeItem(atPath: path)
        }
        guard await waitUntilReady(name, tmux: tmux) else {
            Log.warn("probe: \(account.id) didn't get ready")
            return nil
        }
        return await body(name)
    }

    /// Waits for the input box, answering the probe folder's trust question.
    private static func waitUntilReady(_ name: String, tmux: Tmux) async -> Bool {
        var stable = 0
        var last = ""
        for _ in 0..<30 {
            try? await Task.sleep(for: .milliseconds(1000))
            guard let screen = await tmux.capture(sessions: [name], escapes: false)[name] else { continue }
            if let prompt = PaneReader.read(screen).prompt, prompt.optional != true {
                let text = (prompt.question + " " + (prompt.context ?? "")).lowercased()
                if text.contains("trust"), let yes = prompt.options.first(where: { $0.label.lowercased().hasPrefix("yes") }) {
                    let delta = yes.index - prompt.selectedIndex
                    for _ in 0..<abs(delta) { await tmux.sendKeys(session: name, keys: [delta > 0 ? "Down" : "Up"]) }
                    await tmux.sendKeys(session: name, keys: ["Enter"])
                } else {
                    await tmux.sendKeys(session: name, keys: ["Escape"])
                }
                stable = 0
                continue
            }
            stable = screen == last ? stable + 1 : 0
            last = screen
            if stable >= 2, screen.contains("❯") || screen.contains(">") { return true }
        }
        return false
    }
}

/// Drives an agent's own pickers by their keys, reading the screen after each step.
@MainActor
struct PickerDriver {
    let tmux: Tmux
    let session: String

    func screen() async -> String { await tmux.capture(sessions: [session], escapes: false)[session] ?? "" }

    func prompt() async -> AttentionPrompt? { await tmux.reading(session).prompt }

    /// Types a slash command and waits for the dialog it opens.
    func open(_ command: String, until accept: (AttentionPrompt) -> Bool) async -> AttentionPrompt? {
        await tmux.paste(session: session, text: command, submit: true)
        for _ in 0..<30 {
            try? await Task.sleep(for: .milliseconds(200))
            if let prompt = await prompt(), accept(prompt) { return prompt }
        }
        return nil
    }

    static func isModelPicker(_ prompt: AttentionPrompt) -> Bool {
        let words = (prompt.question + " " + (prompt.hint ?? "") + " " + (prompt.context ?? "")).lowercased()
        return prompt.kind == .choice && prompt.horizontal != true && (words.contains("model") || words.contains("session only"))
    }

    static func effortWord(_ prompt: AttentionPrompt) -> String? { PaneReader.effortWord(prompt) }

    /// Every option of the model picker: up to the first, then down to the last, noting each model's effort.
    func readModelPicker() async -> [ModelOption]? {
        guard var current = await open("/model", until: Self.isModelPicker) else { return nil }
        var found: [Int: ModelOption] = [:]
        func merge(_ prompt: AttentionPrompt) {
            for option in prompt.options where found[option.index] == nil || option.index == prompt.selectedIndex {
                var model = found[option.index] ?? ModelOption(number: option.index, label: option.label, detail: option.detail,
                                                               isDefault: option.isCurrent)
                if option.index == prompt.selectedIndex {
                    let effort = Self.effortWord(prompt)
                    model.defaultEffort = effort
                    model.effortLevels = effort == nil ? [] : nil
                }
                found[option.index] = model
            }
        }
        merge(current)
        for _ in 0..<20 where current.selectedIndex > (current.options.first?.index ?? 1) {
            await tmux.sendKeys(session: session, keys: ["Up"])
            try? await Task.sleep(for: .milliseconds(140))
            guard let next = await prompt(), Self.isModelPicker(next) else { break }
            current = next
            merge(current)
        }
        var still = 0
        for _ in 0..<40 {
            let before = current.selectedIndex
            await tmux.sendKeys(session: session, keys: ["Down"])
            try? await Task.sleep(for: .milliseconds(140))
            guard let next = await prompt(), Self.isModelPicker(next) else { break }
            current = next
            merge(current)
            still = current.selectedIndex <= before ? still + 1 : 0
            if still >= 2 { break }
        }
        let options = found.values.sorted { $0.number < $1.number }
        return options.isEmpty ? nil : options
    }

    /// The effort slider's levels, lowest first.
    func readEffortLevels() async -> [String] {
        guard let slider = await open("/effort", until: { $0.horizontal == true }) else { return [] }
        return slider.options.map { $0.label.lowercased() }
    }
}
