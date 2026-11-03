import Foundation
import Observation

/// One open conversation: its timeline, background tasks and terminal, kept in step with the Mac while on screen.
@Observable
final class SessionModel {
    var session: SessionInfo
    private(set) var items: [TimelineItem] = []
    private(set) var hasEarlier = false
    var tasks: [BackgroundTask] = []
    private(set) var terminal: TerminalFrame?
    private(set) var terminalText: AttributedString = ""
    private(set) var loading = false
    private(set) var loaded = false
    var showTerminal = false
    @ObservationIgnored private var index: [String: Int] = [:]
    @ObservationIgnored private weak var store: HubStore?
    @ObservationIgnored private(set) var isVisible = false
    /// Bumped when new items arrive, so the list can follow the bottom.
    private(set) var tailVersion = 0

    init(session: SessionInfo, store: HubStore) {
        self.session = session
        self.store = store
    }

    var account: Account? { store?.account(session.accountId) }

    var runningTasks: [BackgroundTask] { tasks.filter { $0.status == .running } }

    // MARK: Subscription

    func appear() async {
        isVisible = true
        await subscribe()
    }

    func disappear() async {
        isVisible = false
        try? await store?.client.send(Method.sessionUnsubscribe, SessionRef(sessionId: session.id))
    }

    func subscribe() async {
        if let demo = store?.demo {
            replace(demo.timelines[session.id] ?? [])
            tasks = demo.tasks[session.id] ?? []
            loaded = true
            return
        }
        guard let store, store.isConnected else { return }
        loading = !loaded
        defer { loading = false }
        do {
            let result: SubscribeResult = try await store.client.request(
                Method.sessionSubscribe,
                SubscribeParams(sessionId: session.id, timeline: true, terminal: showTerminal || !session.provider.hasStructuredTranscript,
                                tail: 200))
            session = result.session
            replace(result.items)
            hasEarlier = result.hasEarlier
            tasks = result.tasks
            if let frame = result.terminal { apply(frame) }
            loaded = true
        } catch {
            store.toast = ToastEvent(message: HubClient.describe(error), level: "error")
        }
    }

    func setTerminalVisible(_ visible: Bool) async {
        showTerminal = visible
        await subscribe()
    }

    func loadEarlier() async {
        guard let store, let first = items.first, hasEarlier else { return }
        do {
            let page: PageResult = try await store.client.request(Method.sessionPage, PageParams(sessionId: session.id, beforeId: first.id))
            let known = Set(items.map(\.id))
            replace(page.items.filter { !known.contains($0.id) } + items)
            hasEarlier = page.hasEarlier
        } catch {
            store.toast = ToastEvent(message: HubClient.describe(error), level: "error")
        }
    }

    // MARK: Updates from the Mac

    func apply(_ event: TimelineEvent) {
        if event.reset {
            replace(event.items)
            hasEarlier = false
            tailVersion += 1
            return
        }
        var appended = false
        for item in event.items {
            if let position = index[item.id] {
                items[position] = item
            } else {
                index[item.id] = items.count
                items.append(item)
                appended = true
            }
        }
        if appended { tailVersion += 1 }
    }

    func apply(_ frame: TerminalFrame) {
        guard frame.sequence != terminal?.sequence || frame.lines != terminal?.lines else { return }
        terminal = frame
        terminalText = ANSIRenderer.render(lines: frame.lines, columns: frame.columns)
    }

    private func replace(_ newItems: [TimelineItem]) {
        items = newItems
        index = Dictionary(uniqueKeysWithValues: newItems.enumerated().map { ($1.id, $0) })
        tailVersion += 1
    }

    // MARK: Actions

    /// Sends a message. `replacingDraft` is the Mac's draft the message box showed: the message takes its place.
    func send(_ text: String, replacingDraft: String? = nil) async -> Bool {
        guard let store else { return false }
        do {
            try await store.client.send(Method.sessionSend, SendParams(sessionId: session.id, text: text, submit: true,
                                                                       replacingDraft: replacingDraft))
            return true
        } catch {
            store.toast = ToastEvent(message: HubClient.describe(error), level: "error")
            return false
        }
    }

    func keys(_ keys: [String]) async {
        guard let store else { return }
        await store.perform { try await store.client.send(Method.sessionKeys, KeysParams(sessionId: self.session.id, keys: keys)) }
    }

    func answer(_ prompt: AttentionPrompt, option: AttentionOption, key: String? = nil) async -> Bool {
        guard let store else { return false }
        do {
            try await store.client.send(Method.sessionAnswer, AnswerParams(sessionId: session.id, signature: prompt.signature,
                                                                           optionIndex: option.index, key: key))
            return true
        } catch {
            store.toast = ToastEvent(message: HubClient.describe(error), level: "error")
            return false
        }
    }

    func interrupt() async {
        await keys(["Escape"])
    }

    /// Types your own words into a choice that takes them ("Type something."), then submits.
    func answer(_ prompt: AttentionPrompt, option: AttentionOption, text: String) async -> Bool {
        guard let store else { return false }
        do {
            try await store.client.send(Method.sessionAnswerText,
                                        AnswerTextParams(sessionId: session.id, signature: prompt.signature,
                                                         optionIndex: option.index, text: text))
            return true
        } catch {
            store.toast = ToastEvent(message: HubClient.describe(error), level: "error")
            return false
        }
    }

    /// Switches the model and/or effort through the agent's own picker on the Mac.
    func setModel(_ option: ModelOption?, effort: String?) async -> Bool {
        guard let store else { return false }
        do {
            let params = SessionModelParams(sessionId: session.id, number: option?.number, label: option?.label, effort: effort)
            let _: OKResult = try await store.client.request(Method.sessionModel, params, timeout: .seconds(40))
            return true
        } catch {
            store.toast = ToastEvent(message: HubClient.describe(error), level: "error")
            return false
        }
    }

    func upload(_ data: Data, name: String) async -> String? {
        guard let store else { return nil }
        do {
            let result: UploadResult = try await store.client.request(
                Method.sessionUpload, UploadParams(sessionId: session.id, fileName: name, base64: data.base64EncodedString()),
                timeout: .seconds(60))
            return result.path
        } catch {
            store.toast = ToastEvent(message: HubClient.describe(error), level: "error")
            return nil
        }
    }

    func fullTool(_ id: String, agentId: String? = nil) async -> ToolCall? {
        try? await store?.client.request(Method.sessionTool, ToolParams(sessionId: session.id, toolId: id, agentId: agentId))
    }

    func subagent(_ agentId: String, since: Int) async throws -> SubagentResult {
        guard let store else { throw WireError.failed("Not connected.") }
        return try await store.client.request(Method.sessionSubagent, SubagentParams(sessionId: session.id, agentId: agentId, since: since))
    }

    func taskOutput(path: String, offset: Int64) async throws -> TaskOutputResult {
        guard let store else { throw WireError.failed("Not connected.") }
        return try await store.client.request(Method.sessionTaskOutput, TaskOutputParams(sessionId: session.id, path: path, offset: offset))
    }

    func scrollback(lines: Int) async -> [String] {
        let result: ScrollbackResult? = try? await store?.client.request(Method.sessionScrollback,
                                                                         ScrollbackParams(sessionId: session.id, lines: lines))
        return result?.lines ?? []
    }
}
