import Foundation

/// Runs the hub's sessions: starts each agent in its own tmux session (and Terminal window), watches its screen and
/// conversation file, and reports changes to the phones.
@MainActor
final class SessionManager {
    struct Record: Codable {
        var id: String
        var accountId: String
        var provider: ProviderKind
        var cwd: String
        var customTitle: String?
        var initialTitle: String?
        var createdAt: Date
        var agentSessionId: String?
        var transcriptPath: String?
        var resumeId: String?
        /// A Claude Code background session this one shows (`claude attach <id>`): it runs on in Claude's own
        /// service, so restarting attaches again rather than resuming a copy.
        var attachedTo: String? = nil
    }

    /// A conversation moving here from a terminal tab: its process there, closed once it's idle, and where it showed.
    struct Handoff {
        var pid: Int32
        var tty: String?
        var app: String?
        /// How the phone asked to continue it (model, effort, permission mode).
        var params: CreateSessionParams
        /// Past waiting: closing it there and starting it here.
        var closing = false
        var task: Task<Void, Never>?
    }

    final class Live {
        var record: Record
        var info: SessionInfo
        var handle: TranscriptHandle?
        var terminalHash = 0
        var terminalSequence = 0
        var sawAgentProcess = false
        var events: JSONLTail
        var tasks: [BackgroundTask] = []
        var transcriptInfo: TranscriptInfo?
        var lastPaneText = ""
        /// Claude Code's status line for this session (context, limits, model, effort), and when it last changed.
        var statusUsage: SessionUsage?
        var statusModified: Date?
        /// The model and effort last chosen from the phone, as the agent confirmed them, until it reports its own.
        var picked: (model: String?, effort: String?, at: Date)?
        /// Set while the conversation is still open in a terminal tab, waiting to move here.
        var handoff: Handoff?
        /// When the agent was last started in tmux (an agent that hasn't drawn yet is "starting" for a while).
        var launchedAt = Date.now
        /// The last message-box reading checked against the screen's colours (a grey placeholder looks like text
        /// without them), reused while the screen shows the same text.
        var draftCheck: (seen: String, draft: String?, at: Date)?

        init(record: Record, info: SessionInfo) {
            self.record = record
            self.info = info
            events = JSONLTail(url: URL(fileURLWithPath: "\(HubPaths.events)/\(record.id).jsonl"))
        }
    }

    let tmux: Tmux
    let windows: TerminalWindows
    var accounts: () -> [Account] = { [] }
    var timelineSubscribers: () -> Set<String> = { [] }
    var terminalSubscribers: () -> Set<String> = { [] }
    var onSessionChanged: ((SessionInfo) -> Void)?
    var onSessionRemoved: ((String) -> Void)?
    var onTimeline: ((String, [TimelineItem], Bool) -> Void)?
    var onTasks: ((String, [BackgroundTask]) -> Void)?
    var onTerminal: ((TerminalFrame) -> Void)?
    var onAttention: ((SessionInfo) -> Void)?
    var onFolderUsed: ((String) -> Void)?

    private var order: [String] = []
    private var live: [String: Live] = [:]
    /// Sessions whose model picker the hub is driving: one change at a time, or keys from two drives mix.
    private var changingModel: Set<String> = []
    /// Sessions the hub is typing into (an answer, a model change, a rename): one at a time per session.
    private var driving: Set<String> = []
    /// Polls in a row a session's tmux session has been missing (it ends after two, not on one slow reply).
    private var missing: [String: Int] = [:]

    private func exclusively<T>(_ id: String, _ work: () async throws -> T) async throws -> T {
        guard driving.insert(id).inserted else {
            throw WireError.badRequest("The Mac is still busy with the last choice in this session. One moment.")
        }
        defer { driving.remove(id) }
        return try await work()
    }
    /// Each model's context window, for sessions whose agent doesn't report it (no status line).
    let contextWindows = ContextWindows()
    private var tickCount = 0
    private var loop: Task<Void, Never>?

    init(tmux: Tmux, windows: TerminalWindows) {
        self.tmux = tmux
        self.windows = windows
        contextWindows.onLearned = { [weak self] in self?.refreshUsage() }
    }

    /// Shows newly learnt windows on every session.
    private func refreshUsage() {
        for session in live.values {
            let usage = composedUsage(session)
            guard usage != session.info.usage else { continue }
            session.info.usage = usage
            onSessionChanged?(session.info)
        }
    }

    var sessions: [SessionInfo] { order.compactMap { live[$0]?.info } }

    func info(_ id: String) -> SessionInfo? { live[id]?.info }

    // MARK: Lifecycle

    func start() {
        load()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(for: .milliseconds(450))
            }
        }
    }

    func create(_ params: CreateSessionParams) async throws -> SessionInfo {
        guard let account = accounts().first(where: { $0.id == params.accountId }) else {
            throw WireError.notFound("That account isn't set up on the Mac.")
        }
        let cwd = URL(fileURLWithPath: FileBrowser.expand(params.cwd)).standardizedFileURL.path
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: cwd, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw WireError.notFound("\(cwd) isn't a folder on the Mac.")
        }
        // A conversation open elsewhere on the Mac is taken over, not copied: Claude Code says where it runs.
        if account.provider == .claude, params.takeOver != nil, params.fork != true, let conversation = params.resumeId,
           let running = await runningElsewhere(account: account)?[conversation] {
            switch running.agent.kind {
            case .background: return try await attach(running.agent, account: account, params: params, cwd: cwd)
            case .interactive: return try takeOver(running.agent, host: running.host, account: account, params: params, cwd: cwd)
            }
        }
        let id = Self.newId()
        var adjusted = params
        adjusted.cwd = cwd
        let plan = try Launcher.plan(sessionId: id, account: account, params: adjusted)
        try await tmux.newSession(name: id, directory: cwd, command: plan.tmuxCommand, columns: 150, rows: 46,
                                  environment: ["AGENTHUB_SESSION": id])
        let folder = URL(fileURLWithPath: cwd).lastPathComponent
        await tmux.setOption(session: id, key: "@agenthub_title", value: "\(account.name) · \(folder)")
        let prompt = params.prompt?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        let record = Record(id: id, accountId: account.id, provider: account.provider, cwd: cwd,
                            customTitle: params.title?.nilIfEmpty, initialTitle: prompt.map { Clip.oneLine($0, limit: 80) },
                            createdAt: .now, agentSessionId: plan.agentSessionId, transcriptPath: nil,
                            resumeId: params.fork == true ? nil : params.resumeId)
        let info = SessionInfo(id: id, accountId: account.id, provider: account.provider,
                               title: record.customTitle ?? record.initialTitle ?? folder, cwd: cwd, createdAt: record.createdAt,
                               lastActivity: .now, state: .starting, agentSessionId: plan.agentSessionId)
        let session = Live(record: record, info: info)
        session.handle = makeHandle(record: record, account: account)
        live[id] = session
        order.insert(id, at: 0)
        save()
        onFolderUsed?(cwd)
        Log.info("sessions: started \(id) (\(account.id)) in \(cwd)")
        onSessionChanged?(info)
        if account.provider == .other, let prompt {
            // Other agents take their first message once they're up: typed in after they've drawn their screen.
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(6))
                await self?.tmux.paste(session: id, text: prompt, submit: true)
            }
        }
        if params.openWindow {
            let title = "\(account.name) · \(folder)"
            Task { [weak self] in
                let opened = await self?.windows.open(session: id, title: title, fullScreen: params.fullScreen) ?? false
                if opened { await self?.refreshWindowState(id) }
            }
        }
        return info
    }

    // MARK: Taking over

    /// The account's conversations open outside the hub right now, by conversation id, with where each shows. Nil
    /// when the agent couldn't say.
    func runningElsewhere(account: Account) async -> [String: (agent: RunningAgents.Agent, host: RunningAgents.Host)]? {
        guard let agents = await RunningAgents.list(account: account) else { return nil }
        let hubTTYs = Set(await tmux.listPanes().map(\.tty).filter { !$0.isEmpty })
        let hubConversations = Set(live.values.filter { $0.info.state != .ended }
            .compactMap { $0.info.agentSessionId ?? $0.record.agentSessionId })
        let hosts = await RunningAgents.hosts(of: agents.compactMap(\.pid))
        var found: [String: (agent: RunningAgents.Agent, host: RunningAgents.Host)] = [:]
        for agent in agents where !hubConversations.contains(agent.sessionId) {
            let host = agent.pid.flatMap { hosts[$0] } ?? RunningAgents.Host()
            // An agent in one of the hub's own panes is the hub's.
            if let tty = host.tty, hubTTYs.contains(tty) { continue }
            found[agent.sessionId] = (agent, host)
        }
        return found
    }

    /// Shows one of Claude Code's background sessions as it runs (`claude attach`), with no window: nothing is
    /// restarted, and the session carries on in Claude Code's service when this one ends.
    private func attach(_ agent: RunningAgents.Agent, account: Account, params: CreateSessionParams,
                        cwd fallback: String) async throws -> SessionInfo {
        guard let shortId = agent.shortId else { throw WireError.failed("That background session has no id to attach to.") }
        let cwd = FileManager.default.fileExists(atPath: agent.cwd) ? agent.cwd : fallback
        let id = Self.newId()
        let folder = URL(fileURLWithPath: cwd).lastPathComponent
        let plan = try Launcher.attachPlan(sessionId: id, account: account, cwd: cwd, shortId: shortId,
                                           conversation: agent.sessionId, title: params.title ?? account.name)
        try await tmux.newSession(name: id, directory: cwd, command: plan.tmuxCommand, columns: 150, rows: 46,
                                  environment: ["AGENTHUB_SESSION": id])
        await tmux.setOption(session: id, key: "@agenthub_title", value: "\(account.name) · \(folder)")
        let record = Record(id: id, accountId: account.id, provider: account.provider, cwd: cwd,
                            customTitle: params.title?.nilIfEmpty, initialTitle: agent.name, createdAt: .now,
                            agentSessionId: agent.sessionId, transcriptPath: nil, resumeId: agent.sessionId,
                            attachedTo: shortId)
        let info = SessionInfo(id: id, accountId: account.id, provider: account.provider,
                               title: record.customTitle ?? agent.name ?? folder, cwd: cwd, createdAt: record.createdAt,
                               lastActivity: .now, state: .starting, agentSessionId: agent.sessionId)
        register(record, info, account: account)
        Log.info("sessions: \(id) shows \(account.id)'s background session \(shortId)")
        return info
    }

    /// Moves a conversation open in a terminal tab here. Once the agent there has finished its turn (at once with
    /// `.now`), it's closed and the same conversation continues in the hub; its tab then shows it from here
    /// (`completeHandoff`). Until then the session is listed with the conversation's live timeline.
    private func takeOver(_ agent: RunningAgents.Agent, host: RunningAgents.Host, account: Account,
                          params: CreateSessionParams, cwd fallback: String) throws -> SessionInfo {
        guard let pid = agent.pid else { throw WireError.failed("Couldn't find that session's process on the Mac.") }
        let cwd = FileManager.default.fileExists(atPath: agent.cwd) ? agent.cwd : fallback
        let id = Self.newId()
        let app = host.app ?? "a terminal"
        let waits = agent.busy && params.takeOver != .now
        let record = Record(id: id, accountId: account.id, provider: account.provider, cwd: cwd,
                            customTitle: params.title?.nilIfEmpty, initialTitle: agent.name, createdAt: .now,
                            agentSessionId: agent.sessionId, transcriptPath: nil, resumeId: agent.sessionId)
        var info = SessionInfo(id: id, accountId: account.id, provider: account.provider,
                               title: record.customTitle ?? agent.name ?? URL(fileURLWithPath: cwd).lastPathComponent,
                               cwd: cwd, createdAt: record.createdAt, lastActivity: .now, state: .starting,
                               agentSessionId: agent.sessionId)
        info.stateDetail = waits ? Self.finishingTurn(app) : "Moving here from \(app)…"
        info.movingFrom = waits ? app : nil
        let session = register(record, info, account: account)
        session.handoff = Handoff(pid: pid, tty: host.tty, app: host.app, params: params)
        session.handoff?.task = Task { [weak self] in
            await self?.completeHandoff(id, account: account, params: params, waits: params.takeOver != .now)
        }
        Log.info("sessions: \(id) takes over \(agent.sessionId) from \(app) (pid \(pid)\(waits ? ", after its turn" : ""))")
        return info
    }

    private static func finishingTurn(_ app: String) -> String {
        "Finishing its turn in \(app). Agent Hub takes over after that."
    }

    /// Waits for the agent in the terminal tab to finish its turn (checked again right before, so a turn that has
    /// just started isn't cut off; a question waiting for an answer there doesn't count, as it can't be answered from
    /// here), closes it there (Claude Code saves and exits on SIGTERM), continues the same conversation here, and
    /// shows it in that tab.
    private func completeHandoff(_ id: String, account: Account, params: CreateSessionParams, waits: Bool) async {
        guard let session = live[id], let handoff = session.handoff else { return }
        let app = handoff.app ?? "a terminal"
        if waits {
            while !Task.isCancelled, RunningAgents.isAlive(handoff.pid), await agentBusy(handoff.pid, account: account) {
                if session.info.movingFrom == nil {
                    session.info.stateDetail = Self.finishingTurn(app)
                    session.info.movingFrom = app
                    onSessionChanged?(session.info)
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }
        guard !Task.isCancelled, live[id]?.handoff != nil else { return }
        session.handoff?.closing = true
        session.info.movingFrom = nil
        if RunningAgents.isAlive(handoff.pid) {
            session.info.stateDetail = "Moving here from \(app)…"
            onSessionChanged?(session.info)
            Darwin.kill(handoff.pid, SIGTERM)
            var closed = false
            for _ in 0..<50 where !closed {
                try? await Task.sleep(for: .milliseconds(200))
                closed = !RunningAgents.isAlive(handoff.pid)
            }
            guard closed else {
                endHandoff(id, reason: "Claude didn't close in \(app), so it's still running there.")
                return
            }
        }
        guard live[id]?.handoff != nil else { return }
        var resume = params
        resume.cwd = session.record.cwd
        resume.resumeId = session.record.agentSessionId
        resume.fork = nil
        resume.takeOver = nil
        resume.prompt = nil
        let folder = URL(fileURLWithPath: session.record.cwd).lastPathComponent
        do {
            let plan = try Launcher.plan(sessionId: id, account: account, params: resume)
            try await tmux.newSession(name: id, directory: session.record.cwd, command: plan.tmuxCommand, columns: 150,
                                      rows: 46, environment: ["AGENTHUB_SESSION": id])
        } catch {
            endHandoff(id, reason: "It closed in \(app) but didn't start here. Continue it from History.")
            return
        }
        await tmux.setOption(session: id, key: "@agenthub_title", value: "\(account.name) · \(folder)")
        session.handoff = nil
        session.launchedAt = .now
        session.sawAgentProcess = false
        session.info.stateDetail = nil
        onSessionChanged?(session.info)
        save()
        Log.info("sessions: \(id) continues \(session.record.agentSessionId ?? "?") here, moved from \(app)")
        if let tty = handoff.tty {
            await windows.reattach(session: id, title: "\(account.name) · \(folder)", tty: tty, app: handoff.app)
            await refreshWindowState(id)
        }
    }

    /// Working on a turn right now: the record Claude Code keeps for the process, or failing that, its own list.
    private func agentBusy(_ pid: Int32, account: Account) async -> Bool {
        if let busy = RunningAgents.isBusy(pid: pid, dataDir: account.dataDir) { return busy }
        return await RunningAgents.list(account: account)?.first { $0.pid == pid }?.busy ?? false
    }

    /// Stops waiting for the turn in the terminal tab to end: takes the session over now (the turn stops there).
    func takeOverNow(_ id: String) throws {
        guard let session = live[id], let handoff = session.handoff,
              let account = accounts().first(where: { $0.id == session.record.accountId }) else {
            throw WireError.badRequest("That session isn't waiting to move here.")
        }
        guard !handoff.closing else { return }
        handoff.task?.cancel()
        var params = handoff.params
        params.takeOver = .now
        session.handoff?.task = Task { [weak self] in
            await self?.completeHandoff(id, account: account, params: params, waits: false)
        }
        Log.info("sessions: \(id) takes over now, without waiting for the turn")
    }

    private func endHandoff(_ id: String, reason: String) {
        guard let session = live[id] else { return }
        session.handoff = nil
        session.info.movingFrom = nil
        session.info.state = .ended
        session.info.stateDetail = reason
        onSessionChanged?(session.info)
        save()
        Log.warn("sessions: \(id) wasn't taken over: \(reason)")
    }

    @discardableResult
    private func register(_ record: Record, _ info: SessionInfo, account: Account) -> Live {
        let session = Live(record: record, info: info)
        session.handle = makeHandle(record: record, account: account)
        live[record.id] = session
        order.insert(record.id, at: 0)
        save()
        onFolderUsed?(record.cwd)
        onSessionChanged?(info)
        return session
    }

    func kill(_ id: String, closeWindow: Bool) async {
        guard let session = live[id] else { return }
        if let handoff = session.handoff {
            // Still in its terminal tab: leave it there.
            handoff.task?.cancel()
            session.handoff = nil
            session.info.movingFrom = nil
            session.info.state = .ended
            session.info.stateDetail = nil
            onSessionChanged?(session.info)
            save()
            return
        }
        if closeWindow { await windows.close(session: id) }
        await tmux.kill(session: id)
        session.info.state = .ended
        session.info.attention = nil
        session.info.hasWindow = false
        session.info.stateDetail = nil
        onSessionChanged?(session.info)
        save()
        Log.info("sessions: stopped \(id)")
    }

    func remove(_ id: String) async {
        guard let session = live[id] else { return }
        if session.info.state != .ended { await kill(id, closeWindow: true) }
        live[id] = nil
        order.removeAll { $0 == id }
        for path in ["\(HubPaths.launch)/\(id).zsh", "\(HubPaths.events)/\(id).jsonl", "\(HubPaths.attach)/\(id).command",
                     ClaudeStatus.path(id)] {
            try? FileManager.default.removeItem(atPath: path)
        }
        save()
        onSessionRemoved?(id)
    }

    func rename(_ id: String, title: String) async {
        guard let session = live[id] else { return }
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ").nilIfEmpty
        session.record.customTitle = name
        session.info.title = displayTitle(session)
        save()
        onSessionChanged?(session.info)
        // Claude Code names the conversation too (its /resume list and the phone's history show it). /rename runs
        // at once, even mid-turn, and nothing is sent to the model.
        if let name, session.record.provider == .claude, session.info.state != .ended, session.info.state != .exited,
           driving.insert(id).inserted {
            defer { driving.remove(id) }
            let open = await tmux.reading(id).prompt
            if open == nil || open?.optional == true, await messageBoxIsEmpty(id) {
                await tmux.paste(session: id, text: "/rename \(name)", submit: true)
            }
        }
    }

    // MARK: Input

    /// Types a message into the agent's message box. Anything already typed there (a message the agent handed back
    /// to edit, or words typed on the Mac) is replaced, never joined, and only when the phone has seen it: sent
    /// unchanged, it goes with Return alone, exactly as the agent holds it (pasted text and images included).
    func send(_ id: String, text: String, submit: Bool, replacingDraft: String? = nil) async throws {
        guard let session = live[id], session.info.state != .ended else { throw WireError.notFound("That session has ended.") }
        if let handoff = session.handoff {
            throw WireError.badRequest("Agent Hub takes this session over from \(handoff.app ?? "the terminal") once Claude "
                                       + "finishes its turn there. Send it then.")
        }
        if session.record.provider == .claude || session.record.provider == .codex {
            let plain = await tmux.capture(sessions: [id], escapes: false)[id] ?? ""
            let open = PaneReader.read(plain).prompt
            if open == nil || open?.optional == true, PaneReader.inputDraft(plain: plain) != nil,
               let draft = PaneReader.inputDraft(plain: plain, styled: await tmux.capture(sessions: [id], escapes: true)[id]) {
                guard let seen = replacingDraft, PaneReader.sameDraft(seen, draft) else {
                    session.info.draft = draft
                    onSessionChanged?(session.info)
                    throw WireError.badRequest("Something is typed in the message box on the Mac: “\(Clip.oneLine(draft, limit: 60))”. "
                                               + "Send again to replace it.")
                }
                if submit, PaneReader.sameDraft(text, draft) {
                    await tmux.sendKeys(session: id, keys: ["Enter"])
                    session.info.lastActivity = .now
                    return
                }
                guard await clearMessageBox(id, draft: draft) else {
                    throw WireError.failed("Couldn't clear the message box on the Mac, so nothing was sent.")
                }
            }
        }
        await tmux.paste(session: id, text: text, submit: submit)
        session.info.lastActivity = .now
    }

    /// Empties the agent's message box: to the end of the draft, then Backspace over all of it (more presses than
    /// needed do nothing in an empty box), checked on screen. A cursor left inside the draft gets another pass.
    private func clearMessageBox(_ id: String, draft: String) async -> Bool {
        for pass in 0..<3 {
            // Down to the draft's last row (a no-op on it), then to the end of that row.
            await tmux.sendKey(session: id, key: "Down", count: draft.count / 40 + 2)
            try? await Task.sleep(for: .milliseconds(70))
            await tmux.sendKeys(session: id, keys: ["C-e"])
            try? await Task.sleep(for: .milliseconds(70))
            await tmux.sendKey(session: id, key: "BSpace", count: draft.count + 16 + pass * 32)
            for _ in 0..<6 {
                try? await Task.sleep(for: .milliseconds(120))
                let plain = await tmux.capture(sessions: [id], escapes: false)[id] ?? ""
                guard PaneReader.inputDraft(plain: plain) != nil else { return true }
                let styled = await tmux.capture(sessions: [id], escapes: true)[id]
                if PaneReader.inputDraft(plain: plain, styled: styled) == nil { return true }
            }
        }
        return false
    }

    func keys(_ id: String, keys: [String]) async throws {
        guard let session = live[id], session.info.state != .ended else { throw WireError.notFound("That session has ended.") }
        for key in keys {
            await tmux.sendKeys(session: id, keys: [key])
            if keys.count > 1 { try? await Task.sleep(for: .milliseconds(45)) }
        }
    }

    /// Answers the prompt on screen, but only if it is still the same prompt: the cursor is moved one step at a
    /// time and checked before Return is pressed. A list that scrolls while the cursor moves is followed by the
    /// option's label.
    func answer(_ id: String, signature: String, optionIndex: Int, key: String? = nil, text: String? = nil) async throws {
        try await exclusively(id) {
            try await choose(id, signature: signature, optionIndex: optionIndex, key: key, text: text)
        }
    }

    /// Moves the cursor to the option and confirms it (the hub's own drives use this directly).
    private func choose(_ id: String, signature: String, optionIndex: Int, key: String? = nil, text: String? = nil) async throws {
        guard live[id] != nil else { throw WireError.notFound("That session has ended.") }
        // Return chooses; Space ticks or unticks a checklist item; a letter such as "s" (this session only) works too.
        let press = key.flatMap { $0.isEmpty ? nil : $0 } ?? "Enter"
        guard let first = await tmux.reading(id).prompt, first.signature == signature else {
            throw WireError(code: "prompt_changed", message: "That question is no longer on the Mac's screen.")
        }
        guard let target = first.options.first(where: { $0.index == optionIndex }) else {
            throw WireError.badRequest("That option isn't offered.")
        }
        if first.kind == .yesNo {
            try await keys(id, keys: target.keys ?? ["Enter"])
            return
        }
        var prompt = first
        for attempt in 0..<6 {
            if attempt > 0 {
                guard let now = await tmux.reading(id).prompt, now.question == first.question else {
                    throw WireError.failed("The question closed before the choice was made.")
                }
                prompt = now
            }
            // The same option: by number in a numbered list (numbers don't change when it scrolls), else by label.
            guard let option = prompt.options.first(where: { $0.index == target.index && $0.label == target.label })
                ?? prompt.options.first(where: { $0.label == target.label }) else {
                throw WireError.failed("That option is no longer on the Mac's screen.")
            }
            let delta = option.index - prompt.selectedIndex
            if delta == 0 {
                if let text, !text.isEmpty {
                    // The cursor sits on "Type something.": type into it, then submit.
                    await tmux.sendLiteral(session: id, text: text)
                    try? await Task.sleep(for: .milliseconds(120))
                    await tmux.sendKeys(session: id, keys: ["Enter"])
                } else {
                    await tmux.sendKeys(session: id, keys: [press])
                }
                if press == "Enter" { live[id]?.info.attention = nil }
                return
            }
            let horizontal = prompt.horizontal == true
            for _ in 0..<abs(delta) {
                let step = horizontal ? (delta > 0 ? "Right" : "Left") : (delta > 0 ? "Down" : "Up")
                await tmux.sendKeys(session: id, keys: [step])
                try? await Task.sleep(for: .milliseconds(55))
            }
            // Until the cursor stops moving: keys still on their way would otherwise overshoot the next count.
            var last: Int?
            for _ in 0..<12 {
                try? await Task.sleep(for: .milliseconds(90))
                let now = await tmux.reading(id).prompt?.selectedIndex
                if now == last { break }
                last = now
            }
        }
        throw WireError.failed("The choice couldn't be selected. Use the terminal keys instead.")
    }

    /// Types your own words into a choice that takes them ("Type something."), then submits.
    func answerText(_ params: AnswerTextParams) async throws {
        try await answer(params.sessionId, signature: params.signature, optionIndex: params.optionIndex, key: "Enter",
                         text: params.text)
    }

    // MARK: Model and effort

    /// Switches a running session's model and/or effort through the agent's own picker: Claude Code's /model (the
    /// cursor goes to the model, ◀ ▶ set the effort, then "s" keeps it to this session, or Return makes it the
    /// default); Codex's /model (the model, then its effort).
    func setModel(_ params: SessionModelParams, catalog: ModelCatalog?) async throws {
        guard let session = live[params.sessionId], session.info.state != .ended, session.info.state != .exited else {
            throw WireError.notFound("That session isn't running.")
        }
        guard !changingModel.contains(params.sessionId), !driving.contains(params.sessionId) else {
            throw WireError.badRequest("Already changing the model. One moment.")
        }
        changingModel.insert(params.sessionId)
        driving.insert(params.sessionId)
        defer {
            changingModel.remove(params.sessionId)
            driving.remove(params.sessionId)
        }
        // Read the screen now, not the last poll: any dialog open there (another picker included) comes first.
        if let open = await tmux.reading(params.sessionId).prompt, open.optional != true {
            throw WireError.badRequest("Answer the open question first.")
        }
        guard await messageBoxIsEmpty(params.sessionId) else {
            throw WireError.badRequest("Something is typed in the agent's message box on the Mac. Send or clear it first.")
        }
        let driver = PickerDriver(tmux: tmux, session: params.sessionId)
        switch session.record.provider {
        case .claude:
            try await setClaudeModel(params, catalog: catalog, driver: driver)
        case .codex:
            guard session.info.state != .working else {
                throw WireError.badRequest("Codex can't switch models mid-turn. Try again when it has finished.")
            }
            try await setCodexModel(params, catalog: catalog, driver: driver)
        default:
            throw WireError.badRequest("Use the agent's own /model command in the terminal.")
        }
    }

    private func setClaudeModel(_ params: SessionModelParams, catalog: ModelCatalog?, driver: PickerDriver) async throws {
        guard var picker = await driver.open("/model", until: PickerDriver.isModelPicker) else {
            throw WireError.failed("Claude Code's model picker didn't open.")
        }
        // The model: by its number (they don't change as the list scrolls), checked against its label.
        if let number = params.number {
            for _ in 0..<6 where picker.selectedIndex != number {
                let delta = number - picker.selectedIndex
                for _ in 0..<abs(delta) {
                    await tmux.sendKeys(session: params.sessionId, keys: [delta > 0 ? "Down" : "Up"])
                    try? await Task.sleep(for: .milliseconds(45))
                }
                try? await Task.sleep(for: .milliseconds(150))
                guard let next = await driver.prompt(), PickerDriver.isModelPicker(next) else { break }
                picker = next
            }
            let selected = picker.options.first { $0.index == picker.selectedIndex }
            guard picker.selectedIndex == number, params.label == nil || selected?.label == params.label else {
                await tmux.sendKeys(session: params.sessionId, keys: ["Escape"])
                throw WireError.failed("The model list changed. Pull to refresh the list and try again.")
            }
        }
        // The effort: ◀ or ▶ (toward it, in the order the effort slider showed), until the picker shows it.
        if let effort = params.effort?.lowercased() {
            let order = catalog?.effortLevels ?? []
            var direction = "Right"
            var turned = false
            var previous: String?
            for _ in 0..<14 {
                guard let now = PickerDriver.effortWord(picker) else {
                    await tmux.sendKeys(session: params.sessionId, keys: ["Escape"])
                    throw WireError.badRequest("This model has no effort setting.")
                }
                if now == effort { break }
                if let from = order.firstIndex(of: now), let to = order.firstIndex(of: effort) {
                    direction = to > from ? "Right" : "Left"
                } else if now == previous {
                    // At the end without finding it: go the other way once.
                    guard !turned else { break }
                    turned = true
                    direction = direction == "Right" ? "Left" : "Right"
                }
                previous = now
                await tmux.sendKeys(session: params.sessionId, keys: [direction])
                try? await Task.sleep(for: .milliseconds(160))
                guard let next = await driver.prompt(), PickerDriver.isModelPicker(next) else { break }
                picker = next
            }
            guard PickerDriver.effortWord(picker) == effort else {
                await tmux.sendKeys(session: params.sessionId, keys: ["Escape"])
                throw WireError.badRequest("This model doesn't offer \(effort) effort.")
            }
        }
        // This session only ("s"), unless asked to make it the default (Return). Never Return by accident: without
        // the session-only key the picker is closed and nothing changes.
        let sessionKey = picker.keyActions?.first { $0.label.lowercased().contains("session only") }
        if params.asDefault == true {
            await tmux.sendKeys(session: params.sessionId, keys: ["Enter"])
        } else if let sessionKey {
            await tmux.sendKeys(session: params.sessionId, keys: sessionKey.keys)
        } else {
            await tmux.sendKeys(session: params.sessionId, keys: ["Escape"])
            throw WireError.failed("Claude Code's picker didn't offer \"this session only\", so nothing was changed.")
        }
        // Wait for the picker to close (a busy Mac can take a while). No Escape here: if the picker had just closed,
        // it would interrupt the agent instead.
        var after = ""
        for _ in 0..<20 {
            try? await Task.sleep(for: .milliseconds(150))
            after = await driver.screen()
            if PaneReader.read(after).prompt.map(PickerDriver.isModelPicker) != true { break }
        }
        if let still = PaneReader.read(after).prompt, PickerDriver.isModelPicker(still) {
            throw WireError.failed("Claude Code's model picker is still open on the Mac. Choose there, or press esc.")
        }
        // "Set model to Opus 5.5 for this session only · max effort for this session only": show it at once.
        if let confirmation = PaneReader.modelConfirmation(after), let session = live[params.sessionId] {
            session.picked = (confirmation.model, confirmation.effort ?? params.effort, .now)
            session.info.usage = composedUsage(session)
            onSessionChanged?(session.info)
        }
    }

    private func setCodexModel(_ params: SessionModelParams, catalog: ModelCatalog?, driver: PickerDriver) async throws {
        let id = params.sessionId
        // The model asked for: from the list the phone showed, else by the name it sent.
        let wanted = params.number.flatMap { number in catalog?.options.first { $0.number == number } }
            ?? params.label.map { ModelOption(number: params.number ?? 0, label: $0) }
        guard let picker = await driver.open("/model", until: { $0.kind == .choice && !$0.options.isEmpty }) else {
            throw WireError.failed("Codex's model picker didn't open.")
        }
        func close(_ times: Int) async {
            for _ in 0..<times {
                await tmux.sendKeys(session: id, keys: ["Escape"])
                try? await Task.sleep(for: .milliseconds(150))
            }
        }
        // 1. The model, by its name or id ("Select Model and Effort"). Return only moves on to its effort levels.
        let target = wanted.flatMap { model in
            picker.options.first { option in
                let label = option.label.lowercased()
                return label == model.label.lowercased() || label == model.slug?.lowercased()
            }
        } ?? (wanted == nil ? picker.options.first { $0.isCurrent == true } : nil)
        guard let target else {
            await close(1)
            throw WireError.failed("Codex's picker doesn't show \(wanted?.label ?? "the current model").")
        }
        try await choose(id, signature: picker.signature, optionIndex: target.index)
        // 2. Its effort levels ("Select Reasoning Level for …"); a model without any is already chosen.
        func nextList(after question: String) async -> AttentionPrompt? {
            for _ in 0..<15 {
                try? await Task.sleep(for: .milliseconds(150))
                if let next = await driver.prompt(), next.kind == .choice, next.question != question { return next }
            }
            return nil
        }
        guard var levels = await nextList(after: picker.question) else { return }
        func effortMatches(_ option: AttentionOption, _ effort: String) -> Bool {
            let label = option.label.lowercased().replacingOccurrences(of: "(default)", with: "")
                .trimmingCharacters(in: .whitespaces)
            let squeezed = label.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "-", with: "")
            let spelled = effort.hasPrefix("x") ? "extra" + effort.dropFirst() : effort
            return label == effort || squeezed == effort || squeezed == spelled
        }
        let effort = params.effort?.lowercased()
        var choice = effort.flatMap { effort in levels.options.first { effortMatches($0, effort) } }
        if choice == nil, let effort, let more = levels.options.first(where: { $0.label.lowercased().hasPrefix("more") }) {
            // Max and Ultra are a level further, under "More reasoning…".
            try await choose(id, signature: levels.signature, optionIndex: more.index)
            guard let advanced = await nextList(after: levels.question) else {
                throw WireError.failed("Codex's further reasoning levels didn't open.")
            }
            levels = advanced
            choice = levels.options.first { effortMatches($0, effort) }
        }
        if choice == nil, effort == nil {
            // A new model keeps the effort marked current, else takes its default.
            choice = levels.options.first { $0.isCurrent == true }
                ?? levels.options.first { $0.label.lowercased().contains("(default)") }
        }
        guard let choice else {
            await close(3)
            throw WireError.badRequest("Codex doesn't offer \(effort ?? "that") reasoning for this model.")
        }
        // 3. This session only ("s session"), unless asked to make it the default (Return). Never Return by accident.
        let sessionKey = levels.keyActions?.first { $0.label.lowercased().contains("session") && $0.keyName.count == 1 }
        let key: String
        if params.asDefault == true {
            key = "Enter"
        } else if let sessionKey, let letter = sessionKey.keys.first {
            key = letter
        } else {
            await close(3)
            throw WireError.failed("Codex's picker didn't offer \"this session only\", so nothing was changed.")
        }
        try await choose(id, signature: levels.signature, optionIndex: choice.index, key: key)
        // 4. Show it at once, from Codex's own line under its message box.
        try? await Task.sleep(for: .milliseconds(400))
        if let line = PaneReader.codexModelLine(await driver.screen()), let session = live[id] {
            session.picked = (line.model, line.effort, .now)
            session.info.usage = composedUsage(session)
            onSessionChanged?(session.info)
        }
    }

    /// Nothing typed in the message box, so a slash command typed there can't run into a draft and be sent as a
    /// message.
    private func messageBoxIsEmpty(_ id: String) async -> Bool {
        let plain = await tmux.capture(sessions: [id], escapes: false)[id] ?? ""
        guard PaneReader.inputDraft(plain: plain) != nil else { return true }
        let styled = await tmux.capture(sessions: [id], escapes: true)[id]
        return PaneReader.inputDraft(plain: plain, styled: styled) == nil
    }

    // MARK: Usage

    /// Claude Code's status line, when it has written a new one.
    private func readStatus(_ session: Live) {
        let path = ClaudeStatus.path(session.record.id)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let modified = attributes[.modificationDate] as? Date, modified != session.statusModified else { return }
        session.statusModified = modified
        guard let data = FileManager.default.contents(atPath: path), let usage = ClaudeStatus.usage(from: data) else { return }
        if let learnt = ClaudeStatus.modelWindow(from: data) { contextWindows.learn(model: learnt.model, window: learnt.window) }
        session.statusUsage = usage
        let composed = composedUsage(session)
        guard composed != session.info.usage else { return }
        session.info.usage = composed
        onSessionChanged?(session.info)
    }

    /// The status line where there is one (it knows the window and the limits), else the conversation file.
    private func composedUsage(_ session: Live) -> SessionUsage? {
        let transcript = session.transcriptInfo?.usage
        var usage = session.statusUsage ?? transcript ?? SessionUsage()
        if usage.contextTokens == nil { usage.contextTokens = transcript?.contextTokens }
        if usage.effort == nil { usage.effort = session.transcriptInfo?.effort }
        // A choice made from the phone holds until the status line reports after it.
        if let picked = session.picked, (session.statusModified ?? .distantPast) <= picked.at {
            if let model = picked.model { usage.modelName = model }
            if let effort = picked.effort { usage.effort = effort }
        }
        // No window reported (a session from before the status line): the model's, as Claude Code gave it.
        if usage.contextWindow == nil, usage.contextTokens != nil, let model = session.transcriptInfo?.model ?? session.info.model {
            if let window = contextWindows.window(for: model) {
                usage.contextWindow = window
            } else if let account = accounts().first(where: { $0.id == session.record.accountId }) {
                contextWindows.ask(account, model: model)
            }
        }
        if usage.contextPercent == nil, let tokens = usage.contextTokens, let window = usage.contextWindow, window > 0 {
            usage.contextPercent = min(100, Double(tokens) / Double(window) * 100)
        }
        usage.updatedAt = nil // keeps unchanged readings equal
        return usage == SessionUsage() ? nil : usage
    }

    /// Starts the agent again in an exited session, continuing its conversation where the agent supports it.
    func restart(_ id: String) async throws {
        guard let session = live[id], session.info.state == .exited,
              let account = accounts().first(where: { $0.id == session.record.accountId }) else {
            throw WireError.badRequest("The agent is still running.")
        }
        let resume = session.info.agentSessionId ?? session.record.agentSessionId
        var words = [account.command]
        switch account.provider {
        case .claude where session.record.attachedTo != nil:
            // Still running in Claude Code's background service: show it again.
            words += ["attach", session.record.attachedTo ?? ""]
        case .claude:
            if let resume { words += ["--resume", resume] }
            words += ["--settings", HubPaths.claudeSettings]
        case .codex:
            if let resume { words += ["resume", resume] }
        case .opencode:
            if let resume { words += ["--session", resume] }
        case .antigravity:
            if let resume { words += ["--conversation", resume] }
        case .gemini, .shell, .other:
            break
        }
        let line = ([words[0]] + words.dropFirst().map(Shell.quote)).joined(separator: " ")
        session.sawAgentProcess = false
        session.launchedAt = .now
        session.info.state = .starting
        onSessionChanged?(session.info)
        await tmux.paste(session: id, text: line, submit: true)
    }

    func upload(_ params: UploadParams) throws -> UploadResult {
        guard let data = Data(base64Encoded: params.base64), !data.isEmpty else { throw WireError.badRequest("The photo was empty.") }
        let folder = "\(HubPaths.uploads)/\(params.sessionId)"
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let safe = params.fileName.replacingOccurrences(of: "/", with: "-").nilIfEmpty ?? "photo.jpg"
        let stamp = Int(Date.now.timeIntervalSince1970)
        let path = "\(folder)/\(stamp)-\(safe)"
        try data.write(to: URL(fileURLWithPath: path))
        return UploadResult(path: path)
    }

    // MARK: Reads

    func subscribe(_ params: SubscribeParams) async throws -> SubscribeResult {
        guard let session = live[params.sessionId] else { throw WireError.notFound("That session isn't on the Mac any more.") }
        var items: [TimelineItem] = []
        var hasEarlier = false
        var tasks: [BackgroundTask] = []
        if let handle = session.handle {
            _ = await handle.poll(excluding: claimedPaths(except: params.sessionId))
            let snapshot = handle.snapshot(tail: params.tail)
            items = snapshot.items
            hasEarlier = snapshot.hasEarlier
            tasks = snapshot.tasks
        }
        var frame: TerminalFrame?
        if params.terminal, session.info.state != .ended {
            frame = await terminalFrame(params.sessionId)
        }
        return SubscribeResult(session: session.info, items: items, hasEarlier: hasEarlier, tasks: tasks, terminal: frame)
    }

    func page(_ params: PageParams) -> PageResult {
        guard let handle = live[params.sessionId]?.handle else { return PageResult(items: [], hasEarlier: false) }
        let page = handle.page(before: params.beforeId, limit: params.limit)
        return PageResult(items: page.items, hasEarlier: page.hasEarlier)
    }

    func tool(_ params: ToolParams) throws -> ToolCall {
        guard let tool = live[params.sessionId]?.handle?.fullTool(params.toolId, agentId: params.agentId) else {
            throw WireError.notFound("That tool call isn't in the conversation.")
        }
        return tool
    }

    func subagent(_ params: SubagentParams) throws -> SubagentResult {
        guard let result = live[params.sessionId]?.handle?.subagent(params.agentId, since: params.since) else {
            throw WireError.notFound("That subagent's conversation isn't available yet.")
        }
        return result
    }

    func taskOutput(_ params: TaskOutputParams) throws -> TaskOutputResult {
        let path = URL(fileURLWithPath: params.path).standardizedFileURL.path
        let allowed = ["/private/tmp/claude-\(getuid())/", "/tmp/claude-\(getuid())/", HubPaths.root + "/",
                       NSTemporaryDirectory()]
        guard allowed.contains(where: { path.hasPrefix($0) }) || path.hasSuffix(".output") else {
            throw WireError.badRequest("Only background task output can be read.")
        }
        guard let handle = FileHandle(forReadingAtPath: path) else {
            return TaskOutputResult(text: "", offset: 0, size: 0, truncatedStart: false)
        }
        defer { try? handle.close() }
        let size = Int64((try? handle.seekToEnd()) ?? 0)
        let window: Int64 = 64 * 1024
        var start = params.offset
        var truncated = false
        if start < 0 || start > size {
            start = max(0, size - window)
            truncated = start > 0
        } else if size - start > window {
            start = size - window
            truncated = true
        }
        try? handle.seek(toOffset: UInt64(start))
        let data = (try? handle.readToEnd()) ?? Data()
        return TaskOutputResult(text: ANSIStrip.strip(String(decoding: data, as: UTF8.self)), offset: size, size: size,
                                truncatedStart: truncated)
    }

    func scrollback(_ params: ScrollbackParams) async -> ScrollbackResult {
        let text = await tmux.capture(sessions: [params.sessionId], escapes: true, history: min(max(params.lines, 100), 20_000))
        return ScrollbackResult(lines: (text[params.sessionId] ?? "").components(separatedBy: "\n"))
    }

    func window(_ params: WindowParams) async throws {
        guard let session = live[params.sessionId], session.info.state != .ended else {
            throw WireError.notFound("That session has ended.")
        }
        let account = accounts().first { $0.id == session.record.accountId }
        let title = "\(account?.name ?? "Agent") · \(URL(fileURLWithPath: session.record.cwd).lastPathComponent)"
        switch params.action {
        case "close":
            await windows.close(session: params.sessionId)
        case "open":
            _ = await windows.open(session: params.sessionId, title: title, fullScreen: params.fullScreen)
        default:
            if !(await windows.focus(session: params.sessionId)) {
                _ = await windows.open(session: params.sessionId, title: title, fullScreen: params.fullScreen)
            }
        }
        await refreshWindowState(params.sessionId)
    }

    // MARK: Polling

    private func tick() async {
        tickCount += 1
        // A conversation still moving here from a terminal tab has no tmux session yet; its timeline is read below.
        let alive = order.filter { live[$0]?.info.state != .ended && live[$0]?.handoff == nil }
        let panes = alive.isEmpty ? [] : await tmux.listPanes()
        var paneMap: [String: PaneInfo] = [:]
        for pane in panes where paneMap[pane.session] == nil { paneMap[pane.session] = pane }

        // Sessions whose tmux session is gone have ended (unless tmux itself didn't answer).
        var tmuxAnswered = !panes.isEmpty
        if !tmuxAnswered, !alive.isEmpty {
            let firstAlive = await tmux.hasSession(alive[0])
            tmuxAnswered = !firstAlive
        }
        if tmuxAnswered {
            for id in alive where paneMap[id] != nil { missing[id] = nil }
            for id in alive where paneMap[id] == nil {
                guard let session = live[id] else { continue }
                let stillThere = await tmux.hasSession(id)
                if stillThere {
                    missing[id] = nil
                    continue
                }
                missing[id, default: 0] += 1
                guard missing[id, default: 0] >= 2 else { continue }
                missing[id] = nil
                session.info.state = .ended
                session.info.attention = nil
                session.info.hasWindow = false
                onSessionChanged?(session.info)
                save()
            }
        }
        let running = alive.filter { paneMap[$0] != nil }
        let terminalIds = running.filter { terminalSubscribers().contains($0) }
        let statusIds = tickCount % 2 == 0 ? running : running.filter { terminalIds.contains($0) || live[$0]?.info.state == .starting }

        if !statusIds.isEmpty {
            let texts = await tmux.capture(sessions: statusIds, escapes: false)
            for id in statusIds {
                guard let text = texts[id], let pane = paneMap[id] else { continue }
                let reading = await tmux.reading(id, plain: text)
                let draft = await messageBoxDraft(id, plain: text, reading: reading)
                updateStatus(id, text: text, reading: reading, pane: pane, draft: draft)
            }
        }
        if !terminalIds.isEmpty {
            let texts = await tmux.capture(sessions: terminalIds, escapes: true)
            for id in terminalIds {
                guard let text = texts[id], let pane = paneMap[id], let session = live[id] else { continue }
                let hash = text.hashValue ^ pane.cursorX ^ (pane.cursorY << 16)
                guard hash != session.terminalHash else { continue }
                session.terminalHash = hash
                session.terminalSequence += 1
                onTerminal?(TerminalFrame(sessionId: id, columns: pane.width, rows: pane.height,
                                          lines: text.components(separatedBy: "\n"), cursorX: pane.cursorX,
                                          cursorY: pane.cursorY, sequence: session.terminalSequence))
            }
        }

        let watched = timelineSubscribers()
        for id in order {
            guard let session = live[id], let handle = session.handle else { continue }
            let due = watched.contains(id) || tickCount % 5 == 0 || session.info.state == .starting
            guard due, session.info.state != .ended || tickCount % 20 == 0 else { continue }
            if session.record.provider == .claude {
                readHookEvents(session)
                readStatus(session)
            }
            let result = await handle.poll(excluding: claimedPaths(except: id))
            apply(result, to: session, handle: handle)
        }
    }

    /// What's typed in a Claude Code or Codex message box, for the phone's own box. The plain screen says whether
    /// there's text; its colours (checked again only when that text changes, or every few seconds) say whether
    /// it's a grey placeholder or a suggestion rather than a draft.
    private func messageBoxDraft(_ id: String, plain: String, reading: PaneReader.Reading) async -> String? {
        guard let session = live[id], session.record.provider == .claude || session.record.provider == .codex,
              reading.prompt == nil || reading.prompt?.optional == true,
              let seen = PaneReader.inputDraft(plain: plain) else { return nil }
        if let check = session.draftCheck, check.seen == seen, Date.now.timeIntervalSince(check.at) < 4 { return check.draft }
        let styled = await tmux.capture(sessions: [id], escapes: true)[id]
        let draft = styled == nil ? nil : PaneReader.inputDraft(plain: plain, styled: styled)
        session.draftCheck = (seen, draft, .now)
        return draft
    }

    private func updateStatus(_ id: String, text: String, reading: PaneReader.Reading, pane: PaneInfo, draft: String?) {
        guard let session = live[id] else { return }
        var info = session.info
        let shells: Set<String> = ["zsh", "-zsh", "bash", "-bash", "sh", "fish", "login", "tmux"]
        let atShell = shells.contains(pane.command)
        if !atShell { session.sawAgentProcess = true }
        let state: SessionState
        if let prompt = reading.prompt, prompt.optional != true {
            state = .waiting
        } else if session.record.provider == .shell {
            state = atShell ? .idle : .working
        } else if atShell {
            state = session.sawAgentProcess || Date.now.timeIntervalSince(session.launchedAt) > 25 ? .exited : .starting
        } else if reading.working {
            state = .working
        } else {
            state = .idle
        }
        // Codex shows its model and effort under its message box ("GPT-6.1-Sol xhigh"): always current.
        if session.record.provider == .codex, let line = PaneReader.codexModelLine(text),
           session.picked?.model != line.model || session.picked?.effort != line.effort {
            session.picked = (line.model, line.effort, .now)
            info.usage = composedUsage(session)
        }
        info.state = state
        info.stateDetail = state == .working ? reading.statusLine : nil
        info.attention = reading.prompt
        info.draft = draft
        info.hasWindow = pane.clients > 0
        info.columns = pane.width
        info.rows = pane.height
        if text != session.lastPaneText {
            session.lastPaneText = text
            if state == .working || state == .waiting { info.lastActivity = .now }
        }
        guard info != session.info else { return }
        let newAttention = info.attention != nil && info.attention?.optional != true
            && info.attention?.signature != session.info.attention?.signature
        session.info = info
        onSessionChanged?(info)
        if newAttention { onAttention?(info) }
    }

    private func apply(_ result: TranscriptHandle.PollResult, to session: Live, handle: TranscriptHandle) {
        var changed = false
        if result.located {
            session.info.transcriptAvailable = true
            session.record.transcriptPath = handle.locatedPath
            save()
            changed = true
        }
        if let info = result.info {
            session.transcriptInfo = info
            session.info.title = displayTitle(session)
            session.info.model = info.model ?? session.info.model
            session.info.permissionMode = info.permissionMode ?? session.info.permissionMode
            session.info.gitBranch = info.gitBranch ?? session.info.gitBranch
            session.info.lastMessage = info.lastMessage ?? session.info.lastMessage
            session.info.usage = composedUsage(session)
            if let agentId = info.agentSessionId, agentId != session.info.agentSessionId {
                session.info.agentSessionId = agentId
                session.record.agentSessionId = agentId
                save()
            }
            if let activity = info.lastActivity, activity > (session.info.lastActivity ?? .distantPast) {
                session.info.lastActivity = activity
            }
            changed = true
        }
        if let tasks = result.tasks {
            session.tasks = tasks
            session.info.runningTasks = tasks.count(where: { $0.status == .running })
            onTasks?(session.record.id, tasks)
            changed = true
        }
        if !result.changes.isEmpty || result.reset {
            onTimeline?(session.record.id, result.changes, result.reset)
        }
        if changed { onSessionChanged?(session.info) }
    }

    /// Claude's SessionStart hook says which file the conversation is in now (it changes after /clear or /resume).
    private func readHookEvents(_ session: Live) {
        guard case .lines(let events) = session.events.read() else { return }
        for event in events where event["hook_event_name"] as? String == "SessionStart" {
            guard let path = event["transcript_path"] as? String else { continue }
            let sessionId = event["session_id"] as? String
            if path != session.handle?.locatedPath {
                Log.info("sessions: \(session.record.id) now writes \(URL(fileURLWithPath: path).lastPathComponent) (\(event["source"] as? String ?? "start"))")
                session.handle?.follow(path: path, sessionId: sessionId)
                if let sessionId { session.record.agentSessionId = sessionId }
                session.record.transcriptPath = path
                session.record.customTitle = session.record.customTitle
                save()
            }
        }
    }

    private func refreshWindowState(_ id: String) async {
        guard let session = live[id] else { return }
        let panes = await tmux.listPanes()
        if let pane = panes.first(where: { $0.session == id }) {
            let hasWindow = pane.clients > 0
            if hasWindow != session.info.hasWindow {
                session.info.hasWindow = hasWindow
                onSessionChanged?(session.info)
            }
        }
    }

    private func terminalFrame(_ id: String) async -> TerminalFrame? {
        let panes = await tmux.listPanes()
        guard let pane = panes.first(where: { $0.session == id }), let session = live[id] else { return nil }
        let text = await tmux.capture(sessions: [id], escapes: true)[id] ?? ""
        session.terminalSequence += 1
        session.terminalHash = text.hashValue ^ pane.cursorX ^ (pane.cursorY << 16)
        return TerminalFrame(sessionId: id, columns: pane.width, rows: pane.height, lines: text.components(separatedBy: "\n"),
                             cursorX: pane.cursorX, cursorY: pane.cursorY, sequence: session.terminalSequence)
    }

    private func claimedPaths(except id: String) -> Set<String> {
        Set(live.values.compactMap { $0.record.id == id ? nil : ($0.handle?.locatedPath ?? $0.record.transcriptPath) })
    }

    private func displayTitle(_ session: Live) -> String {
        session.record.customTitle
            ?? session.transcriptInfo?.title?.nilIfEmpty
            ?? session.record.initialTitle
            ?? URL(fileURLWithPath: session.record.cwd).lastPathComponent
    }

    private func makeHandle(record: Record, account: Account) -> TranscriptHandle? {
        guard account.provider.hasStructuredTranscript else { return nil }
        return TranscriptHandle(account: account, cwd: record.cwd, startedAt: record.createdAt,
                                agentSessionId: record.agentSessionId, resumeId: record.resumeId,
                                knownPath: record.transcriptPath)
    }

    // MARK: Persistence

    private func save() {
        let records = order.compactMap { live[$0]?.record }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(records) else { return }
        try? data.write(to: URL(fileURLWithPath: HubPaths.sessions), options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: HubPaths.sessions)
    }

    private func load() {
        guard let data = FileManager.default.contents(atPath: HubPaths.sessions) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let records = try? decoder.decode([Record].self, from: data) else { return }
        let accounts = accounts()
        for record in records {
            let folder = URL(fileURLWithPath: record.cwd).lastPathComponent
            let info = SessionInfo(id: record.id, accountId: record.accountId, provider: record.provider,
                                   title: record.customTitle ?? record.initialTitle ?? folder, cwd: record.cwd,
                                   createdAt: record.createdAt, state: .starting, agentSessionId: record.agentSessionId)
            let session = Live(record: record, info: info)
            session.sawAgentProcess = true
            if let account = accounts.first(where: { $0.id == record.accountId }) {
                session.handle = makeHandle(record: record, account: account)
            }
            // Old hook events were already applied; start reading after them.
            _ = session.events.read()
            live[record.id] = session
            order.append(record.id)
        }
        Log.info("sessions: restored \(records.count) session(s)")
    }

    static func newId() -> String {
        let letters = Array("abcdefghjkmnpqrstuvwxyz23456789")
        return "ah-" + String((0..<6).map { _ in letters.randomElement()! })
    }
}
