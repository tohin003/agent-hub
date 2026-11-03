import SwiftUI

/// An account's past conversations on the Mac. Tap one to continue it on the Mac, in the folder it ran in and with
/// the settings it last used; one open right now outside Agent Hub is taken over, not copied. Touch and hold to read
/// it or continue a copy.
struct HistoryList: View {
    var account: Account
    /// Set when choosing a conversation for the New Session sheet instead of continuing it right away.
    var onPick: ((HistoryEntry) -> Void)?
    @Environment(HubStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var entries: [HistoryEntry]?
    @State private var error: String?
    @State private var search = ""
    @State private var starting: String?
    @State private var reading: HistoryEntry?
    @State private var confirming: HistoryEntry?

    var body: some View {
        List {
            if let entries {
                ForEach(filtered(entries)) { entry in
                    Button {
                        open(entry)
                    } label: {
                        HistoryRow(entry: entry, running: isRunning(entry), starting: starting == entry.id)
                    }
                    .buttonStyle(.plain)
                    .disabled(starting != nil)
                    .contextMenu {
                        Button("Continue", systemImage: "play.fill") { open(entry) }
                        Button("Continue as a Copy", systemImage: "plus.square.on.square") { Task { await start(entry, fork: true) } }
                        Button("Read", systemImage: "text.bubble") { reading = entry }
                        Divider()
                        Button("Copy Conversation ID", systemImage: "number") { UIPasteboard.general.string = entry.id }
                        if let cwd = entry.cwd {
                            Button("Copy Folder Path", systemImage: "folder") { UIPasteboard.general.string = cwd }
                        }
                    }
                    .swipeActions(edge: .trailing) {
                        Button("Read", systemImage: "text.bubble") { reading = entry }.tint(Theme.starlightDeep)
                    }
                    // On the row itself, so the question points at the conversation you tapped.
                    .modifier(ContinueDialog(entry: entry,
                                             isPresented: Binding(get: { confirming?.id == entry.id },
                                                                  set: { if !$0, confirming?.id == entry.id { confirming = nil } })) { fork, takeOver in
                        Task { await start(entry, fork: fork, takeOver: takeOver) }
                    })
                }
            } else if let error {
                ContentUnavailableView("Couldn't Load", systemImage: "exclamationmark.triangle", description: Text(error))
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
        .overlay {
            if let entries, entries.isEmpty {
                ContentUnavailableView("No Conversations", systemImage: "clock",
                                       description: Text("\(account.name) has no saved conversations on this Mac."))
            }
        }
        .searchable(text: $search)
        .navigationTitle(account.name)
        .navigationDestination(item: $reading) { entry in
            HistoryTranscript(account: account, entry: entry)
        }
        .task { await load() }
        .refreshable { await load() }
    }

    private func isRunning(_ entry: HistoryEntry) -> Bool {
        store.sessions.contains { $0.agentSessionId == entry.id && $0.state != .ended }
    }

    private func open(_ entry: HistoryEntry) {
        if let onPick {
            onPick(entry)
            dismiss()
        } else if isRunning(entry) {
            Task { await start(entry, fork: false) }
        } else if entry.running?.kind == .background {
            // Claude's background service: opened as it runs, nothing stops or restarts.
            Task { await start(entry, fork: false, takeOver: .whenIdle) }
        } else if entry.activeElsewhere == true {
            confirming = entry
        } else {
            Task { await start(entry, fork: false) }
        }
    }

    private func start(_ entry: HistoryEntry, fork: Bool, takeOver: TakeOver? = nil) async {
        starting = entry.id
        await store.resume(entry, account: account, fork: fork, takeOver: takeOver ?? .whenIdle)
        starting = nil
    }

    private func filtered(_ entries: [HistoryEntry]) -> [HistoryEntry] {
        guard !search.isEmpty else { return entries }
        return entries.filter { $0.title.localizedStandardContains(search) || ($0.cwd ?? "").localizedStandardContains(search) }
    }

    private func load() async {
        do {
            entries = try await store.client.request(Method.historyList, HistoryParams(accountId: account.id), timeout: .seconds(40))
        } catch {
            self.error = HubClient.describe(error)
        }
    }
}

/// One past conversation: its title, where and when it ran, and the settings it continues with.
struct HistoryRow: View {
    var entry: HistoryEntry
    var running: Bool
    var starting: Bool

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.title)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    if let cwd = entry.cwd {
                        Label(cwd.lastPathComponent, systemImage: "folder")
                    }
                    if let date = entry.updatedAt {
                        Text(date, format: .relative(presentation: .named))
                    }
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                .labelStyle(.titleAndIcon)
                if let settings = entry.settings {
                    Text(settings)
                        .font(.caption.monospaced())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if starting {
                ProgressView()
            } else if running {
                Label("Running", systemImage: "dot.radiowaves.left.and.right")
                    .font(.footnote)
                    .foregroundStyle(.green)
            } else if let elsewhere = entry.running {
                VStack(alignment: .trailing, spacing: 2) {
                    Label(elsewhere.kind == .background ? "Background" : elsewhere.app ?? "Terminal",
                          systemImage: elsewhere.kind == .background ? "rectangle.stack" : "terminal")
                        .font(.footnote)
                        .foregroundStyle(.green)
                    if elsewhere.busy || elsewhere.waitingFor != nil {
                        Text(elsewhere.busy ? "Working" : "Waiting for you")
                            .font(.caption2)
                            .foregroundStyle(elsewhere.busy ? Color.secondary : Color.orange)
                    }
                }
            } else {
                Image(systemName: "play.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, 2)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityHint(running ? "Opens the running session"
                           : entry.running != nil ? "Continues the session that's open on the Mac, here"
                           : "Continues this conversation on the Mac")
    }
}

/// A past conversation, read-only, with a button to continue it.
struct HistoryTranscript: View {
    var account: Account
    var entry: HistoryEntry
    @Environment(HubStore.self) private var store
    @State private var confirming = false
    @State private var items: [TimelineItem]?
    @State private var error: String?

    var body: some View {
        Group {
            if let items {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Theme.rowSpacing) {
                        ForEach(items) { item in
                            TimelineRow(item: item, model: nil)
                        }
                    }
                    .padding()
                }
                .defaultScrollAnchor(.bottom)
            } else if let error {
                ContentUnavailableView("Can't Read This Conversation", systemImage: "doc.questionmark", description: Text(error))
            } else {
                ProgressView()
            }
        }
        .navigationTitle(entry.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Continue", systemImage: "play.fill") {
                    let running = store.sessions.contains { $0.agentSessionId == entry.id && $0.state != .ended }
                    if running {
                        Task { await store.resume(entry, account: account) }
                    } else if entry.running?.kind == .background {
                        Task { await store.resume(entry, account: account, takeOver: .whenIdle) }
                    } else if entry.activeElsewhere == true {
                        confirming = true
                    } else {
                        Task { await store.resume(entry, account: account) }
                    }
                }
                .modifier(ContinueDialog(entry: entry, isPresented: $confirming) { fork, takeOver in
                    Task { await store.resume(entry, account: account, fork: fork, takeOver: takeOver ?? .whenIdle) }
                })
            }
        }
        .task {
            do {
                let page: PageResult = try await store.client.request(Method.historyTimeline,
                                                                      HistoryTimelineParams(accountId: account.id, id: entry.id),
                                                                      timeout: .seconds(40))
                items = page.items
            } catch {
                self.error = HubClient.describe(error)
            }
        }
    }
}

/// How to continue a conversation that's open elsewhere on the Mac. One Claude Code reports open in a terminal tab
/// is taken over: the same session carries on in Agent Hub (after the turn it's working on, unless you stop that)
/// and its tab shows it, so nothing is copied and no window opens. For others, all the hub knows is that the file
/// changed lately: continue alongside, or in a copy.
private struct ContinueDialog: ViewModifier {
    var entry: HistoryEntry
    @Binding var isPresented: Bool
    var onContinue: (_ fork: Bool, _ takeOver: TakeOver?) -> Void

    @ViewBuilder func body(content: Content) -> some View {
        if let running = entry.running, running.kind == .terminal {
            content.confirmationDialog("Continue Here?", isPresented: $isPresented, titleVisibility: .visible) {
                Button(running.busy ? "Continue When This Turn Ends" : "Continue Here") { onContinue(false, .whenIdle) }
                if running.busy {
                    Button("Stop the Turn and Continue Now", role: .destructive) { onContinue(false, .now) }
                }
                Button("Continue as a Copy") { onContinue(true, nil) }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(message(running))
            }
        } else {
            content.confirmationDialog("This conversation may be open in another terminal", isPresented: $isPresented,
                                       titleVisibility: .visible) {
                Button("Continue as a Copy") { onContinue(true, nil) }
                Button("Continue It Here Too") { onContinue(false, nil) }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("It changed in the last two minutes. Two agents writing the same conversation can mix them up; a copy starts from the same point with its own history.")
            }
        }
    }

    private func message(_ running: RunningElsewhere) -> String {
        let app = running.app ?? "a terminal"
        let situation: String
        if running.busy {
            situation = "Claude is working on it in \(app) right now. Agent Hub takes it over when this turn ends; you can follow along until then."
        } else if let waiting = running.waitingFor {
            situation = "In \(app), Claude is waiting for an answer (\(waiting)). It can't be answered from here: taking over closes that question, and you can ask Claude to carry on."
        } else {
            situation = "It's open in \(app) on your Mac. Agent Hub takes it over from there."
        }
        let tab = running.app == "Terminal"
            ? " Its Terminal tab keeps showing it, now from Agent Hub."
            : " Its \(app) tab gets a note saying how to show it there."
        return situation + " The same conversation carries on; nothing is copied." + tab
    }
}
