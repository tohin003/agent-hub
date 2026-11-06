import SwiftUI

/// One session: the conversation as chat (or the live terminal), what's running in the background, any choice
/// waiting for you, and the message box.
struct SessionScreen: View {
    @Bindable var model: SessionModel
    @Environment(HubStore.self) private var store
    @State private var showingTasks = false
    @State private var showingKeys = false
    @State private var confirmStop = false
    @State private var showingUsage = false
    @State private var showingModels = false
    @State private var renaming = false
    @State private var newTitle = ""

    /// Agents that report their context and limits, and whose model can be chosen from here.
    private var reportsUsage: Bool { [.claude, .codex, .opencode].contains(model.session.provider) }
    private var choosesModel: Bool {
        [.claude, .codex].contains(model.session.provider) && model.session.state != .ended && model.session.state != .exited
    }

    private var hasChat: Bool { model.session.provider.hasStructuredTranscript }
    private var terminalMode: Bool { model.showTerminal || !hasChat }

    var body: some View {
        Group {
            if terminalMode {
                TerminalView(model: model)
            } else {
                TimelineList(model: model)
            }
        }
        .safeAreaBar(edge: .bottom) {
            VStack(spacing: 8) {
                if let prompt = model.session.attention {
                    AttentionCard(prompt: prompt, model: model)
                        .id(prompt.signature)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                } else if model.session.agentUpdated == true {
                    AgentUpdatedCard(session: model.session)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                if showingKeys || terminalMode {
                    KeyBar(model: model)
                }
                if choosesModel, model.session.attention == nil {
                    HStack {
                        ModelPill(model: model, showingModels: $showingModels)
                        Spacer()
                    }
                }
                ComposerBar(model: model, showingKeys: $showingKeys)
            }
            .padding(.horizontal)
            .padding(.bottom, 6)
            .animation(.snappy, value: model.session.attention?.signature)
            .animation(.snappy, value: model.session.agentUpdated)
        }
        .navigationTitle(model.session.title)
        .navigationSubtitle(subtitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarVisibility(.hidden, for: .tabBar)
        .toolbar {
            if reportsUsage {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingUsage = true
                    } label: {
                        ContextRing(percent: model.session.usage?.contextPercent)
                    }
                    .accessibilityLabel("Usage")
                    .accessibilityValue(model.session.usage?.contextPercent.map { "Context \(Int($0.rounded())) percent used" } ?? "")
                }
            }
            if hasChat {
                ToolbarItem(placement: .primaryAction) {
                    Button(model.showTerminal ? "Chat" : "Terminal", systemImage: model.showTerminal ? "bubble.left.and.text.bubble.right" : "terminal") {
                        Task { await model.setTerminalVisible(!model.showTerminal) }
                    }
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button("Background Tasks", systemImage: "gearshape.2") { showingTasks = true }
                    .badge(model.runningTasks.count)
            }
            ToolbarItem(placement: .primaryAction) {
                Menu("More", systemImage: "ellipsis") {
                    Button("Rename…", systemImage: "pencil") {
                        newTitle = model.session.title
                        renaming = true
                    }
                    if reportsUsage {
                        Button("Usage", systemImage: "gauge.with.dots.needle.33percent") { showingUsage = true }
                    }
                    if choosesModel {
                        Button("Model and Effort", systemImage: "cpu") { showingModels = true }
                    }
                    Divider()
                    Button("Show on Mac", systemImage: "macwindow") { Task { await store.showOnMac(model.session.id) } }
                    Button("Open Another Window", systemImage: "macwindow.badge.plus") {
                        Task {
                            await store.perform {
                                try await store.client.send(Method.sessionWindow,
                                                            WindowParams(sessionId: model.session.id, action: "open"))
                            }
                        }
                    }
                    if model.session.state == .exited {
                        Button("Start the Agent Again", systemImage: "arrow.clockwise") { Task { await store.restart(model.session.id) } }
                    }
                    if model.session.state == .ended, model.session.agentSessionId != nil, let account = model.account {
                        Button("Continue This Conversation", systemImage: "play.fill") {
                            Task { await continueConversation(account) }
                        }
                    }
                    Divider()
                    Button("Copy Folder Path", systemImage: "doc.on.doc") { UIPasteboard.general.string = model.session.cwd }
                    if let id = model.session.agentSessionId {
                        Button("Copy Conversation ID", systemImage: "number") { UIPasteboard.general.string = id }
                    }
                    Divider()
                    Button("Stop Session", systemImage: "stop.fill", role: .destructive) { confirmStop = true }
                        .disabled(model.session.state == .ended)
                }
                // From the ••• button it was chosen in.
                .confirmationDialog("Stop this session?", isPresented: $confirmStop, titleVisibility: .visible) {
                    Button("Stop Session and Close Its Window", role: .destructive) {
                        Task { await store.kill(model.session.id) }
                    }
                } message: {
                    Text("The agent and its terminal on the Mac are closed. Work it already did stays.")
                }
            }
        }
        .sheet(isPresented: $showingTasks) {
            TasksSheet(model: model)
        }
        .sheet(isPresented: $showingUsage) {
            UsageSheet(model: model)
        }
        .sheet(isPresented: $showingModels) {
            ModelSheet(model: model)
        }
        .alert("Rename Session", isPresented: $renaming) {
            TextField("Name", text: $newTitle)
                .submitLabel(.done)
            Button("Rename") {
                let title = newTitle
                Task { await store.rename(model.session.id, to: title) }
            }
            .disabled(newTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(model.session.provider == .claude ? "Claude Code names the conversation too, so its history shows it."
                                                   : "The name shows in Agent Hub's session list.")
        }
        .onAppear { AttentionNotifier.shared.visibleSessionId = model.session.id }
        .onDisappear {
            if AttentionNotifier.shared.visibleSessionId == model.session.id { AttentionNotifier.shared.visibleSessionId = nil }
        }
        .task {
            await model.appear()
            // `-openTerminal YES` shows the terminal first (checks and screenshots).
            if UserDefaults.standard.bool(forKey: "openTerminal"), hasChat { await model.setTerminalVisible(true) }
            // `-demoSheet usage|models|tasks` opens that sheet (screenshots).
            switch UserDefaults.standard.string(forKey: "demoSheet") {
            case "usage": showingUsage = true
            case "models": showingModels = true
            case "tasks": showingTasks = true
            default: break
            }
        }
        .onDisappear { Task { await model.disappear() } }
        .sensoryFeedback(.warning, trigger: model.session.attention?.signature) { _, new in new != nil }
        // The agent finished its turn while you watched: a soft, satisfied tap.
        .sensoryFeedback(.success, trigger: model.session.state) { old, new in old == .working && new == .idle }
    }

    /// An ended session's conversation, continued in a new session: same folder, same mode and model.
    private func continueConversation(_ account: Account) async {
        guard let id = model.session.agentSessionId else { return }
        let entry = HistoryEntry(id: id, accountId: account.id, title: model.session.title, cwd: model.session.cwd,
                                 updatedAt: model.session.lastActivity, sizeBytes: nil, mode: model.session.permissionMode,
                                 model: model.session.model)
        await store.resume(entry, account: account)
    }

    private var subtitle: String {
        let account = model.account?.name ?? model.session.accountId
        var parts = [account, model.session.cwd.lastPathComponent]
        if let branch = model.session.gitBranch { parts.append(branch) }
        return parts.joined(separator: " · ")
    }
}
