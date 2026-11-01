import SwiftUI

/// Every session on your Mac, across all accounts: the ones waiting for you first, then the busy ones.
struct SessionsView: View {
    @Namespace private var zoom
    @Environment(HubStore.self) private var store
    @State private var path: [String] = []
    @State private var showingNew = false
    @State private var filter: String?
    @State private var renaming: SessionInfo?
    @State private var newTitle = ""

    var body: some View {
        NavigationStack(path: $path) {
            content
                .navigationTitle("Sessions")
                .navigationSubtitle(statusLine)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        ConnectionBadge()
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Menu("Filter", systemImage: filter == nil ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill") {
                            Picker("Account", selection: $filter) {
                                Text("All Accounts").tag(String?.none)
                                ForEach(store.accounts.filter { account in store.sessions.contains { $0.accountId == account.id } }) { account in
                                    Text(account.name).tag(Optional(account.id))
                                }
                            }
                        }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button("New Session", systemImage: "plus") { showingNew = true }
                            .disabled(!store.isConnected)
                    }
                }
                .navigationDestination(for: String.self) { id in
                    if let session = store.sessions.first(where: { $0.id == id }) {
                        SessionScreen(model: store.model(for: session))
                            .navigationTransition(.zoom(sourceID: id, in: zoom))
                    } else {
                        ContentUnavailableView("Session Ended", systemImage: "moon.zzz",
                                               description: Text("This session isn't on your Mac any more."))
                    }
                }
        }
        .sheet(isPresented: $showingNew) {
            NewSessionSheet { session in
                showingNew = false
                path = [session.id]
            }
        }
        .alert("Rename Session", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Title", text: $newTitle)
            Button("Rename") {
                if let session = renaming { Task { await store.rename(session.id, to: newTitle) } }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
        .task {
            if UserDefaults.standard.bool(forKey: "showNewSession") {
                try? await Task.sleep(for: .seconds(2))
                showingNew = true
            }
        }
        .onChange(of: store.pendingSessionId) { _, id in
            guard let id else { return }
            path = [id]
            store.pendingSessionId = nil
        }
        // One asked for before the list appeared (a notification or link that launched the app).
        .onAppear {
            guard let id = store.pendingSessionId else { return }
            path = [id]
            store.pendingSessionId = nil
        }
    }

    @ViewBuilder private var content: some View {
        if !store.isConnected && store.sessions.isEmpty {
            NotConnectedView()
        } else if store.sessions.isEmpty {
            EmptySessionsView { showingNew = true }
        } else {
            List {
                sessionSection("Needs You", sessions: visible.filter { $0.state == .waiting })
                sessionSection("Working", sessions: visible.filter { $0.state == .working || $0.state == .starting })
                sessionSection("Ready", sessions: visible.filter { $0.state == .idle })
                sessionSection("Stopped", sessions: visible.filter { $0.state == .exited || $0.state == .ended })
            }
            .listStyle(.insetGrouped)
            .refreshable { await store.refreshSessions() }
            .animation(.default, value: store.sessions.map(\.state))
        }
    }

    private var statusLine: String {
        if store.isConnected {
            let running = store.sessions.count(where: { $0.state != .ended })
            return "\(store.macName) · \(running) running"
        }
        return store.isConnecting ? "Connecting to \(store.macName)…" : "Not connected"
    }

    private var visible: [SessionInfo] {
        let list = filter.map { id in store.sessions.filter { $0.accountId == id } } ?? store.sessions
        return list.sorted { ($0.lastActivity ?? $0.createdAt) > ($1.lastActivity ?? $1.createdAt) }
    }

    @ViewBuilder
    private func sessionSection(_ title: String, sessions: [SessionInfo]) -> some View {
        if !sessions.isEmpty {
            Section(title) {
                ForEach(sessions) { session in
                    NavigationLink(value: session.id) {
                        SessionRow(session: session, account: store.account(session.accountId))
                            .matchedTransitionSource(id: session.id, in: zoom)
                    }
                    .swipeActions(edge: .trailing) {
                        if session.state == .ended {
                            Button("Remove", systemImage: "trash", role: .destructive) {
                                Task { await store.remove(session.id) }
                            }
                        } else {
                            Button("Stop", systemImage: "stop.fill", role: .destructive) {
                                Task { await store.kill(session.id) }
                            }
                        }
                    }
                    .swipeActions(edge: .leading) {
                        if session.state != .ended {
                            Button("Show on Mac", systemImage: "macwindow") {
                                Task { await store.showOnMac(session.id) }
                            }
                            .tint(Theme.starlightDeep)
                        }
                    }
                    .contextMenu {
                        if session.state != .ended {
                            Button("Show on Mac", systemImage: "macwindow") { Task { await store.showOnMac(session.id) } }
                        }
                        Button("Rename", systemImage: "pencil") {
                            newTitle = session.title
                            renaming = session
                        }
                        Button("Copy Folder Path", systemImage: "doc.on.doc") { UIPasteboard.general.string = session.cwd }
                        Divider()
                        if session.state == .ended {
                            Button("Remove", systemImage: "trash", role: .destructive) { Task { await store.remove(session.id) } }
                        } else {
                            Button("Stop Session", systemImage: "stop.fill", role: .destructive) { Task { await store.kill(session.id) } }
                        }
                    }
                }
            }
        }
    }
}
