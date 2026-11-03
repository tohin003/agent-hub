import Foundation
import Observation
import UIKit
import UserNotifications

/// Everything the app shows about your Mac: the connection, its accounts, the sessions, and the conversations open
/// on screen. Views read it from the environment and call its actions.
@Observable
final class HubStore {
    let client = HubClient()
    private(set) var settings = HubSettings.load()
    private(set) var hub: HubInfo?
    private(set) var accounts: [Account] = []
    private(set) var sessions: [SessionInfo] = []
    private(set) var connectionError: String?
    private(set) var isConnecting = false
    var toast: ToastEvent?
    /// A session the app was asked to open (from a notification or link).
    var pendingSessionId: String?
    /// Another session needs you while the app is open: the glass banner at the top.
    var inAppAlert: InAppAlert?
    /// A made-up Mac for screenshots (`-demo <file>`): shown instead of a live connection.
    private(set) var demo: DemoSnapshot?

    @ObservationIgnored private var models: [String: SessionModel] = [:]
    @ObservationIgnored private var reconnectTask: Task<Void, Never>?
    @ObservationIgnored private var wantsConnection = false

    init() {
        client.onEvent = { [weak self] event, data in self?.handle(event: event, data: data) }
        client.onDisconnect = { [weak self] in self?.scheduleReconnect() }
    }

    var isConnected: Bool { demo != nil || client.isConnected }

    /// Shows a made-up Mac instead of connecting (screenshots).
    func loadDemo(_ snapshot: DemoSnapshot) {
        demo = snapshot
        hub = snapshot.hub
        accounts = snapshot.accounts
        sessions = snapshot.sessions
        catalogs = snapshot.catalogs
    }

    var connectedHost: String? {
        if case .connected(let host) = client.state { host } else { nil }
    }

    var macName: String { hub?.macName ?? settings.macName }

    /// Sessions waiting on you (a survey after a turn waits on nobody).
    var waitingCount: Int {
        sessions.count(where: { $0.attention != nil && $0.attention?.optional != true && $0.state != .ended })
    }

    func account(_ id: String) -> Account? { accounts.first { $0.id == id } }

    // MARK: Connection

    func connect() async {
        wantsConnection = true
        if await attemptConnection() {
            reconnectTask?.cancel()
        } else if reconnectTask == nil {
            scheduleReconnect()
        }
    }

    /// One try at every address. True when connected.
    private func attemptConnection() async -> Bool {
        guard settings.isConfigured else {
            connectionError = "This build doesn't know your Mac yet. Copy the pairing link from Agent Hub's menu on your Mac and open it here."
            return false
        }
        guard !isConnecting else { return isConnected }
        isConnecting = true
        defer { isConnecting = false }
        do {
            let hello = try await client.connect(settings, device: UIDevice.current.name)
            hub = hello.hub
            accounts = hello.accounts
            sessions = hello.sessions
            connectionError = nil
            // Re-subscribe the conversations that are open on screen.
            for model in models.values where model.isVisible {
                await model.subscribe()
            }
            return true
        } catch is CancellationError {
            return false
        } catch {
            connectionError = HubClient.describe(error)
            return false
        }
    }

    func disconnect() {
        wantsConnection = false
        reconnectTask?.cancel()
        client.disconnect()
    }

    func scheduleReconnect() {
        guard wantsConnection else { return }
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            var delay = 1.0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(delay))
                guard let self, !Task.isCancelled else { return }
                if self.isConnected { break }
                if await self.attemptConnection() { break }
                delay = min(delay * 2, 30)
            }
            if !Task.isCancelled { self?.reconnectTask = nil }
        }
    }

    func applyPairing(_ url: URL) async -> Bool {
        guard let paired = HubSettings.fromPairingLink(url) else { return false }
        paired.save()
        settings = paired
        await connect()
        return true
    }

    func updateSettings(_ new: HubSettings) async {
        new.save()
        settings = new
        await connect()
    }

    // MARK: Events

    private func handle(event: String, data: JSONValue) {
        switch event {
        case Event.sessionUpdated:
            guard let info = try? data.decode(SessionInfo.self) else { return }
            if let index = sessions.firstIndex(where: { $0.id == info.id }) {
                sessions[index] = info
            } else {
                sessions.insert(info, at: 0)
            }
            models[info.id]?.session = info
        case Event.sessionRemoved:
            guard let ref = try? data.decode(SessionRef.self) else { return }
            sessions.removeAll { $0.id == ref.sessionId }
        case Event.timeline:
            guard let timeline = try? data.decode(TimelineEvent.self) else { return }
            models[timeline.sessionId]?.apply(timeline)
        case Event.tasks:
            guard let tasks = try? data.decode(TasksEvent.self) else { return }
            models[tasks.sessionId]?.tasks = tasks.tasks
        case Event.terminal:
            guard let frame = try? data.decode(TerminalFrame.self) else { return }
            models[frame.sessionId]?.apply(frame)
        case Event.hub:
            hub = try? data.decode(HubInfo.self)
        case Event.accounts:
            if let list = try? data.decode([Account].self) { accounts = list }
        case Event.toast:
            toast = try? data.decode(ToastEvent.self)
        default:
            break
        }
    }

    // MARK: Sessions

    func model(for session: SessionInfo) -> SessionModel {
        if let model = models[session.id] { return model }
        let model = SessionModel(session: session, store: self)
        models[session.id] = model
        return model
    }

    func createSession(_ params: CreateSessionParams) async throws -> SessionInfo {
        let info: SessionInfo = try await client.request(Method.sessionCreate, params, timeout: .seconds(40))
        if !sessions.contains(where: { $0.id == info.id }) { sessions.insert(info, at: 0) }
        return info
    }

    /// Continues a past conversation in the folder it ran in, with the settings it last used. A conversation the hub
    /// is already running is simply opened. One that Claude Code says is open elsewhere on the Mac is taken over
    /// rather than copied (`takeOver`: after its current turn, or now): the same session, shown in its own Terminal
    /// tab, so no new window. A copy (`fork`) is always a new conversation.
    @discardableResult
    func resume(_ entry: HistoryEntry, account: Account, fork: Bool = false, takeOver: TakeOver = .whenIdle) async -> Bool {
        if !fork, let running = sessions.first(where: { $0.agentSessionId == entry.id && $0.state != .ended }) {
            pendingSessionId = running.id
            return true
        }
        let params = CreateSessionParams(accountId: account.id, cwd: entry.cwd ?? "~", resumeId: entry.id, mode: entry.mode,
                                         model: entry.model, effort: entry.effort, fork: fork,
                                         title: fork ? "Copy of \(entry.title)" : entry.title,
                                         takeOver: fork ? nil : takeOver)
        do {
            let session = try await createSession(params)
            pendingSessionId = session.id
            return true
        } catch {
            toast = ToastEvent(message: HubClient.describe(error), level: "error")
            return false
        }
    }

    /// A session still in a terminal tab waiting for its turn to end: take it over now (the turn stops there).
    func takeOverNow(_ id: String) async {
        await perform { try await self.client.send(Method.sessionTakeOverNow, SessionRef(sessionId: id)) }
    }

    func kill(_ id: String) async {
        await perform { try await self.client.send(Method.sessionKill, KillParams(sessionId: id)) }
    }

    func remove(_ id: String) async {
        await perform { try await self.client.send(Method.sessionRemove, SessionRef(sessionId: id)) }
        sessions.removeAll { $0.id == id }
        models[id] = nil
    }

    func rename(_ id: String, to title: String) async {
        await perform { try await self.client.send(Method.sessionRename, RenameParams(sessionId: id, title: title)) }
    }

    func showOnMac(_ id: String, fullScreen: Bool = true) async {
        await perform { try await self.client.send(Method.sessionWindow, WindowParams(sessionId: id, action: "focus", fullScreen: fullScreen)) }
    }

    func restart(_ id: String) async {
        await perform { try await self.client.send("session.restart", SessionRef(sessionId: id)) }
    }

    func refreshSessions() async {
        guard isConnected else {
            await connect()
            return
        }
        if let list: [SessionInfo] = try? await client.request(Method.sessionsList, Empty()) { sessions = list }
        if let info: HubInfo = try? await client.request(Method.macStatus, Empty()) { hub = info }
    }

    // MARK: Usage, models, screen

    /// Model lists already read, per account.
    private(set) var catalogs: [String: ModelCatalog] = [:]

    func accountUsage(_ accountId: String, refresh: Bool = false) async throws -> AccountUsage {
        if let demo { return demo.usage[accountId] ?? AccountUsage(accountId: accountId, limits: [], notes: [], sections: [], fetchedAt: .now) }
        return try await client.request(Method.accountUsage, AccountParams(accountId: accountId, refresh: refresh),
                                        timeout: .seconds(75))
    }

    func modelCatalog(_ accountId: String, refresh: Bool = false) async throws -> ModelCatalog {
        if let catalog = demo?.catalogs[accountId] { return catalog }
        if !refresh, let catalog = catalogs[accountId] { return catalog }
        let catalog: ModelCatalog = try await client.request(Method.accountModels,
                                                             AccountParams(accountId: accountId, refresh: refresh),
                                                             timeout: .seconds(90))
        catalogs[accountId] = catalog
        return catalog
    }

    /// Slash commands per account, as the agent lists them (read once a day on the Mac).
    private(set) var commands: [String: [SlashCommand]] = [:]

    func slashCommands(_ accountId: String) async -> [SlashCommand] {
        if let known = commands[accountId] { return known }
        if demo != nil { return account(accountId)?.provider.slashCommands ?? [] }
        let fallback = account(accountId)?.provider.slashCommands ?? []
        guard let listed: [SlashCommand] = try? await client.request(Method.accountCommands, AccountParams(accountId: accountId),
                                                                    timeout: .seconds(75)) else { return fallback }
        commands[accountId] = listed
        return listed
    }

    /// Answers from a notification's button: iOS wakes the app for a few seconds, so connect if needed, answer, and
    /// say so in a follow-up notification if it couldn't (the hub only answers while that same question is on screen).
    func answerFromNotification(session: String, signature: String, option: Int, text: String?) async {
        if !isConnected { await connect() }
        for _ in 0..<40 where !isConnected { try? await Task.sleep(for: .milliseconds(250)) }
        do {
            guard isConnected else { throw WireError.failed("Couldn't reach your Mac.") }
            if let text {
                try await client.send(Method.sessionAnswerText,
                                      AnswerTextParams(sessionId: session, signature: signature, optionIndex: option, text: text))
            } else {
                try await client.send(Method.sessionAnswer,
                                      AnswerParams(sessionId: session, signature: signature, optionIndex: option, key: "Enter"))
            }
        } catch {
            let content = UNMutableNotificationContent()
            content.title = "Couldn't answer"
            content.body = "\(HubClient.describe(error)) Open Agent Hub to answer there."
            content.userInfo = ["session": session]
            content.threadIdentifier = session
            try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "answer-failed-\(session)",
                                                                                     content: content, trigger: nil))
        }
    }

    /// Turns the Mac's live screen on or off in Agent Hub.
    func setScreenSharing(_ enabled: Bool) async -> Bool {
        do {
            let info: HubInfo = try await client.request(Method.screenSharing, ScreenSharingParams(enabled: enabled))
            hub = info
            return true
        } catch {
            toast = ToastEvent(message: HubClient.describe(error), level: "error")
            return false
        }
    }

    /// Whether the live screen is on (an older hub has no switch: on).
    var screenSharing: Bool { hub?.screenSharing ?? true }

    /// Covers the Mac's displays while you drive it from here (people near it see a message), or uncovers them.
    func setPrivacyScreen(_ on: Bool) async {
        do {
            let info: HubInfo = try await client.request(Method.screenPrivacy, ScreenSharingParams(enabled: on))
            hub = info
        } catch {
            toast = ToastEvent(message: HubClient.describe(error), level: "error")
        }
    }

    /// Whether the Mac's privacy screen is up (nil: this hub doesn't have one).
    var privacyScreen: Bool? { hub?.privacyScreen }

    func refreshHub() async {
        if let info: HubInfo = try? await client.request(Method.macStatus, Empty()) { hub = info }
    }

    /// Runs a request and turns a failure into a toast.
    func perform(_ work: () async throws -> Void) async {
        do {
            try await work()
        } catch {
            toast = ToastEvent(message: HubClient.describe(error), level: "error")
        }
    }
}
