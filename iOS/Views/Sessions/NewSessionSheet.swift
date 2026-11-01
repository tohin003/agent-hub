import SwiftUI
import UserNotifications

/// Start an agent on the Mac: which account, which folder, and how it should begin.
struct NewSessionSheet: View {
    var onStarted: (SessionInfo) -> Void
    @Environment(HubStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var accountId: String?
    @State private var folder: String?
    @State private var roots: FSRoots?
    @State private var prompt = ""
    @State private var mode = ""
    @State private var model = ""
    @State private var title = ""
    @State private var openWindow = true
    @State private var fullScreen = true
    @State private var starting = false
    @State private var resume: HistoryEntry?
    @State private var browsing = false

    private var account: Account? { store.accounts.first { $0.id == accountId } }

    var body: some View {
        NavigationStack {
            Form {
                Section("Agent") {
                    AccountPicker(selection: $accountId)
                        .listRowInsets(EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12))
                }
                Section {
                    Button {
                        browsing = true
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "folder.fill")
                                .font(.title3)
                                .foregroundStyle(.tint)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(folder?.lastPathComponent ?? "Choose a Folder")
                                    .foregroundStyle(.primary)
                                if let folder {
                                    Text(folder.abbreviatingHome)
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                        .truncationMode(.middle)
                                }
                            }
                            Spacer(minLength: 8)
                            Image(systemName: "chevron.right")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .accessibilityHint("Browse the Mac's folders")
                    if let recents = roots?.recents, !recents.isEmpty {
                        ForEach(recents.prefix(5)) { entry in
                            Button {
                                folder = entry.path
                            } label: {
                                HStack {
                                    Label(entry.name, systemImage: entry.isGitRepo ? "arrow.triangle.branch" : "clock")
                                        .foregroundStyle(.primary)
                                    Spacer()
                                    if folder == entry.path {
                                        Image(systemName: "checkmark").foregroundStyle(.tint)
                                    }
                                }
                            }
                        }
                    }
                } header: {
                    Text("Folder on \(store.macName)")
                } footer: {
                    Text("Recent folders appear here. Browse to pick another, or make a new one.")
                }
                if resume == nil {
                    Section {
                        TextField("What should it work on? (optional)", text: $prompt, axis: .vertical)
                            .lineLimit(3...8)
                    } header: {
                        Text("First Message")
                    }
                }
                if let account {
                    Section("Options") {
                        if !account.provider.launchModes.isEmpty {
                            Picker("Permissions", selection: $mode) {
                                ForEach(account.provider.launchModes) { mode in
                                    Text(mode.title).tag(mode.id)
                                }
                            }
                            if let detail = account.provider.launchModes.first(where: { $0.id == mode })?.detail {
                                Text(detail).font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                        if account.provider != .shell {
                            TextField("Model (optional)", text: $model)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                        }
                        TextField("Title (optional)", text: $title)
                        Toggle("Open a Window on the Mac", isOn: $openWindow)
                        Toggle("Full Screen", isOn: $fullScreen)
                            .disabled(!openWindow)
                    }
                    if account.provider != .shell {
                        Section {
                            NavigationLink {
                                HistoryList(account: account) { entry in
                                    resume = entry
                                    if let cwd = entry.cwd { folder = cwd }
                                }
                            } label: {
                                if let resume {
                                    Label {
                                        VStack(alignment: .leading) {
                                            Text("Continue: \(resume.title)").lineLimit(2)
                                            if let date = resume.updatedAt {
                                                Text(date, format: .relative(presentation: .named)).font(.footnote).foregroundStyle(.secondary)
                                            }
                                            if let settings = resume.settings {
                                                Text("With its own settings: \(settings)")
                                                    .font(.caption.monospaced())
                                                    .foregroundStyle(.secondary)
                                            }
                                        }
                                    } icon: {
                                        Image(systemName: "arrow.uturn.forward.circle.fill")
                                    }
                                } else {
                                    Label("Continue a Past Conversation", systemImage: "clock.arrow.circlepath")
                                }
                            }
                            if resume != nil {
                                Button("Start Fresh Instead", systemImage: "xmark.circle", role: .destructive) { resume = nil }
                            }
                        }
                    }
                }
            }
            .navigationTitle("New Session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if starting {
                        ProgressView()
                    } else {
                        Button("Start", systemImage: "play.fill", action: start)
                            .disabled(accountId == nil || folder == nil)
                    }
                }
            }
            .navigationDestination(isPresented: $browsing) {
                FolderBrowser(startPath: folder ?? roots?.places.first(where: { $0.name == "Projects" })?.path ?? roots?.home ?? "~") { path in
                    folder = path
                    browsing = false
                }
            }
            .task { await load() }
            .onChange(of: store.accounts) { _, _ in preselectAccount() }
            .onChange(of: accountId) { _, _ in
                mode = ""
                resume = nil
            }
        }
        .sensoryFeedback(.success, trigger: starting) { old, new in old && !new }
    }

    /// The account used most recently, else the first one installed.
    private func preselectAccount() {
        guard accountId == nil else { return }
        let recent = store.sessions.first.map(\.accountId).flatMap { id in store.accounts.first { $0.id == id } }
        accountId = recent?.id ?? store.accounts.first { $0.available }?.id
    }

    private func load() async {
        preselectAccount()
        do {
            let result: FSRoots = try await store.client.request(Method.fsRoots, Empty())
            roots = result
            if folder == nil { folder = result.recents.first?.path }
        } catch {
            store.toast = ToastEvent(message: HubClient.describe(error), level: "error")
        }
    }

    private func start() {
        guard let accountId, let folder else { return }
        starting = true
        let params = CreateSessionParams(accountId: accountId, cwd: folder, prompt: resume == nil ? prompt : nil,
                                         resumeId: resume?.id, mode: resume?.mode ?? mode, model: resume?.model ?? model,
                                         effort: resume?.effort, title: title.isEmpty ? resume?.title : title,
                                         openWindow: openWindow, fullScreen: fullScreen)
        Task {
            do {
                let session = try await store.createSession(params)
                starting = false
                onStarted(session)
                // Now it's clear why: so a session that needs you can say so while you're in another app.
                _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
            } catch {
                starting = false
                store.toast = ToastEvent(message: HubClient.describe(error), level: "error")
            }
        }
    }
}

/// A grid of the Mac's agent accounts.
struct AccountPicker: View {
    @Binding var selection: String?
    @Environment(HubStore.self) private var store

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 10)], spacing: 10) {
            ForEach(store.accounts) { account in
                Button {
                    selection = account.id
                } label: {
                    VStack(spacing: 6) {
                        ProviderGlyph(account: account, provider: account.provider, size: 40)
                        Text(account.name)
                            .font(.footnote.weight(.medium))
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                            .foregroundStyle(.primary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 84)
                    .padding(6)
                    .background(selection == account.id ? Color.accentColor.opacity(0.14) : Color.clear,
                                in: .rect(cornerRadius: 14))
                    .overlay {
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(selection == account.id ? Color.accentColor : Color.secondary.opacity(0.2),
                                    lineWidth: selection == account.id ? 2 : 1)
                    }
                    .opacity(account.available ? 1 : 0.45)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(account.name)
                .accessibilityAddTraits(selection == account.id ? .isSelected : [])
            }
        }
        .sensoryFeedback(.selection, trigger: selection)
    }
}
