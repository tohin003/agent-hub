import AppKit
import Observation

/// The Mac side of Agent Hub: the server the phone talks to, the sessions it runs, the screen it shares.
@MainActor
@Observable
final class Hub {
    static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"

    private(set) var config = HubConfig()
    let token: String
    let tailnet = TailnetGuard()
    let screen = ScreenService()
    /// A phone's live drag (double-tap and drag): the Mac's button never stays down after it.
    let mouseDrag = MouseDragSession(poster: SystemMousePoster())
    let audio = AudioService()
    /// The picture and sound over UDP, for phones that set it up.
    @ObservationIgnored let media = MediaTransport()
    @ObservationIgnored let curtain = PrivacyCurtain()
    private(set) var tmux: Tmux?
    private(set) var sessions: SessionManager?
    @ObservationIgnored private(set) var logoService: LogoService?
    @ObservationIgnored let accountUsage = AccountUsageReader()
    @ObservationIgnored private(set) var accountCommands: AccountCommands?
    @ObservationIgnored private(set) var modelCatalogs: ModelCatalogs?
    @ObservationIgnored private var server: HubServer?
    @ObservationIgnored private var clients: [UUID: ClientConnection] = [:]
    private(set) var connectedDevices: [String] = []
    private(set) var sessionList: [SessionInfo] = []
    private(set) var listening: [String] = []
    private(set) var problem: String?
    /// The iPhone app's signing (renew.sh's state), read again every minute and after any renewal action.
    private(set) var renewal: RenewalInfo?
    @ObservationIgnored private var lastAlert: [String: Date] = [:]

    init() {
        HubPaths.prepare()
        token = PairingToken.loadOrCreate()
    }

    /// The accounts, each with the logo its CLI draws (read from its own screen).
    var accounts: [Account] {
        config.accounts.map { account in
            var copy = account
            copy.logo = logoService?.logos[account.id]
            return copy
        }
    }

    func start() {
        // A hub that crashed or was killed with the privacy screen up may have left the displays black.
        if let given = DisplayBlackout.recover(output: SystemDisplayOutput(), markerPath: DisplayBlackout.markerPath), given > 0 {
            Log.warn("privacy screen: gave back \(given) display(s) that an earlier hub left black")
        }
        Launcher.installClaudeHooks()
        config = HubConfig.load()
        screen.enabled = config.screenSharing
        audio.enabled = config.screenSharing
        media.onStarted = { [weak self] client in
            if client.channel == .screen { self?.screen.mediaStarted(client) }
        }
        media.onEvent = { [weak self] event, client in
            switch client.channel {
            case .screen: self?.screen.mediaEvent(event, from: client)
            case .audio: self?.audio.mediaEvent(event, from: client)
            case .control, .unknown: break
            }
        }
        media.onEnded = { [weak self] client in
            switch client.channel {
            case .screen: self?.screen.mediaEnded(client)
            case .audio: self?.audio.mediaEnded(client)
            case .control, .unknown: break
            }
        }
        curtain.onUnlocked = { [weak self] in self?.privacyScreenUnlocked() }
        curtain.onCovered = { [weak self] in self?.privacyScreenMoved() }
        if config.repoPath == nil, let repo = Bundle.main.object(forInfoDictionaryKey: "AgentHubRepository") as? String,
           !repo.isEmpty, !repo.contains("$(") {
            config.repoPath = repo
        }
        config.save()
        tailnet.requireSameUser = config.requireSameTailnetUser
        tailnet.allowLAN = config.listenOnLAN

        if let tmux = Tmux() {
            self.tmux = tmux
            let manager = SessionManager(tmux: tmux, windows: TerminalWindows(tmux: tmux))
            manager.accounts = { [weak self] in self?.config.accounts ?? [] }
            manager.timelineSubscribers = { [weak self] in self?.subscribed(terminal: false) ?? [] }
            manager.terminalSubscribers = { [weak self] in self?.subscribed(terminal: true) ?? [] }
            manager.onSessionChanged = { [weak self] info in self?.sessionChanged(info) }
            manager.onSessionRemoved = { [weak self] id in
                self?.broadcast(Event.sessionRemoved, SessionRef(sessionId: id))
                self?.sessionList = self?.sessions?.sessions ?? []
            }
            manager.onTimeline = { [weak self] id, items, reset in
                self?.send(to: id, terminal: false, Event.timeline, TimelineEvent(sessionId: id, items: items, reset: reset))
            }
            manager.onTasks = { [weak self] id, tasks in
                self?.send(to: id, terminal: false, Event.tasks, TasksEvent(sessionId: id, tasks: tasks))
            }
            manager.onTerminal = { [weak self] frame in
                self?.send(to: frame.sessionId, terminal: true, Event.terminal, frame)
            }
            manager.onAttention = { [weak self] info in self?.alert(info) }
            manager.onFolderUsed = { [weak self] path in self?.rememberFolder(path) }
            sessions = manager
            manager.start()
            sessionList = manager.sessions

            let logos = LogoService(tmux: tmux)
            logos.onChange = { [weak self] _ in
                guard let self else { return }
                self.broadcast(Event.accounts, self.accounts)
            }
            logoService = logos
            let catalogs = ModelCatalogs(tmux: tmux)
            modelCatalogs = catalogs
            let commands = AccountCommands(tmux: tmux)
            accountCommands = commands
            Task { [weak self] in
                // Read logos from sessions as they start; probe accounts never used, now and twice a day.
                var ticks = 0
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(3))
                    guard let self, let manager = self.sessions else { return }
                    for session in manager.sessions where session.state != .ended
                        && Date.now.timeIntervalSince(session.createdAt) < 180 && logos.needsLogo(session.accountId) {
                        await logos.observe(sessionId: session.id, accountId: session.accountId,
                                            age: Date.now.timeIntervalSince(session.createdAt))
                    }
                    ticks += 1
                    if ticks % 20 == 1 { self.refreshRenewal() }
                    if ticks == 10 || ticks % 14_400 == 0 {
                        await logos.probeMissing(self.config.accounts.filter(\.available))
                    }
                    // The model lists the phone's picker shows, read once per account (and every three days on use).
                    if ticks == 40 {
                        await catalogs.probeMissing(self.config.accounts.filter(\.available))
                        await commands.probeMissing(self.config.accounts.filter(\.available))
                    }
                }
            }
        } else {
            problem = "tmux isn't installed. Run: brew install tmux"
            Log.error("hub: tmux not found")
        }

        let server = HubServer(port: config.port, token: token, tailnet: tailnet)
        server.onConnection = { [weak self] client in self?.register(client) }
        self.server = server
        Task {
            await tailnet.refresh()
            bind()
            // Follow Tailscale coming up, going down or changing address.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(20))
                if await tailnet.refresh() { bind() }
            }
        }
        Log.info("hub: started, version \(Self.version)")
    }

    private func bind() {
        server?.bind(hosts: tailnet.listenHosts)
        listening = server?.boundHosts ?? []
        media.listen(on: tailnet.ipv4)
    }

    // MARK: Clients

    private func register(_ client: ClientConnection) {
        clients[client.id] = client
        client.onFrame = { [weak self] client, frame in
            guard let self else { return }
            Task { await self.handle(frame, from: client) }
        }
        client.onClose = { [weak self] client in
            guard let self else { return }
            self.screen.stopWatching(client: client)
            self.mouseDrag.clientLeft(client.id)
            self.audio.stopListening(client: client)
            self.media.end(client)
            self.clients[client.id] = nil
            self.updateDevices()
            Log.info("hub: \(client.device) (\(client.remote)) disconnected")
        }
        Log.info("hub: connection from \(client.remote)")
    }

    func updateDevices() {
        connectedDevices = Array(Set(clients.values.filter { $0.channel == .control }.map(\.device))).sorted()
    }

    private func subscribed(terminal: Bool) -> Set<String> {
        var ids = Set<String>()
        for client in clients.values where client.channel == .control {
            ids.formUnion(terminal ? client.terminalSubscriptions : client.subscriptions)
        }
        return ids
    }

    func broadcast<T: Encodable>(_ event: String, _ value: T) {
        for client in clients.values where client.channel == .control {
            client.emit(event, value)
        }
    }

    private func send<T: Encodable>(to sessionId: String, terminal: Bool, _ event: String, _ value: T) {
        for client in clients.values where client.channel == .control {
            let set = terminal ? client.terminalSubscriptions : client.subscriptions
            if set.contains(sessionId) { client.emit(event, value) }
        }
    }

    private func sessionChanged(_ info: SessionInfo) {
        broadcast(Event.sessionUpdated, info)
        sessionList = sessions?.sessions ?? []
    }

    var hubInfo: HubInfo {
        HubInfo(macName: Host.current().localizedName ?? "Mac", user: NSUserName(), version: Self.version,
                tailscaleName: tailnet.dnsName, tailscaleIP: tailnet.ipv4, port: config.port,
                screenRecording: ScreenService.screenRecordingAllowed, accessibility: InputInjector.trusted,
                tmuxPath: tmux?.path, terminalApp: config.terminalApp, renewal: RenewalState.read(),
                clients: connectedDevices.count, screenSharing: config.screenSharing, privacyScreen: curtain.isOn)
    }

    // MARK: Settings

    private func rememberFolder(_ path: String) {
        config.recentFolders.removeAll { $0 == path }
        config.recentFolders.insert(path, at: 0)
        config.recentFolders = Array(config.recentFolders.prefix(12))
        config.save()
    }

    func refreshRenewal() {
        let latest = RenewalState.read()
        guard latest != renewal else { return }
        renewal = latest
        broadcast(Event.hub, hubInfo)
    }

    /// Turns the live screen on or off for every phone.
    func setScreenSharing(_ enabled: Bool) {
        config.screenSharing = enabled
        config.save()
        screen.enabled = enabled
        audio.enabled = enabled
        Log.info("screen: sharing turned \(enabled ? "on" : "off")")
        broadcast(Event.hub, hubInfo)
    }

    /// Covers the Mac's displays while the phone drives it, or uncovers them.
    func setPrivacyScreen(_ on: Bool) async throws {
        if on { try curtain.show() } else { curtain.hide() }
        // While it's up, the streams leave it out: the phone keeps seeing what's under it.
        await screen.hide(windows: curtain.windowIDs)
        broadcast(Event.hub, hubInfo)
    }

    /// A display came or went, so the privacy screen has new windows: the streams leave those out instead.
    private func privacyScreenMoved() {
        Task { await screen.hide(windows: curtain.windowIDs) }
    }

    private func privacyScreenUnlocked() {
        broadcast(Event.hub, hubInfo)
        broadcast(Event.toast, ToastEvent(message: "The privacy screen was unlocked at the Mac.", level: "warning"))
        Task { await screen.hide(windows: []) }
    }

    func setNtfy(_ url: String?) {
        config.ntfyURL = url?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        config.save()
    }

    /// A pairing link the phone can open (agenthub://pair?...), for re-pairing without rebuilding the app.
    var pairingLink: String {
        var components = URLComponents()
        components.scheme = "agenthub"
        components.host = "pair"
        var hosts: [String] = []
        if let name = tailnet.dnsName { hosts.append(name) }
        if let ip = tailnet.ipv4 { hosts.append(ip) }
        components.queryItems = [
            URLQueryItem(name: "hosts", value: hosts.joined(separator: ",")),
            URLQueryItem(name: "port", value: "\(config.port)"),
            URLQueryItem(name: "token", value: token),
            URLQueryItem(name: "name", value: Host.current().localizedName ?? "Mac"),
        ]
        return components.string ?? ""
    }

    // MARK: Alerts while the phone app is closed

    /// Posts a short alert to the person's ntfy topic when a session waits for them and no phone is connected.
    private func alert(_ info: SessionInfo) {
        guard let urlText = config.ntfyURL, let url = URL(string: urlText) else { return }
        guard connectedDevices.isEmpty else { return }
        if let last = lastAlert[info.id], Date.now.timeIntervalSince(last) < 60 { return }
        lastAlert[info.id] = .now
        let account = config.accounts.first { $0.id == info.accountId }?.name ?? "An agent"
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("\(account) needs you", forHTTPHeaderField: "Title")
        request.setValue("agenthub://session/\(info.id)", forHTTPHeaderField: "Click")
        request.setValue("high", forHTTPHeaderField: "Priority")
        request.setValue("robot", forHTTPHeaderField: "Tags")
        let folder = URL(fileURLWithPath: info.cwd).lastPathComponent
        request.httpBody = Data("\(info.attention?.question ?? "Waiting for your answer") — \(folder)".utf8)
        URLSession.shared.dataTask(with: request).resume()
    }
}
