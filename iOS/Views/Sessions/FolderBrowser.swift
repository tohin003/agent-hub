import SwiftUI

/// Browse the Mac's folders, make a new one, and choose where the session starts.
struct FolderBrowser: View {
    var startPath: String
    var onChoose: (String) -> Void
    @Environment(HubStore.self) private var store
    @State private var path: String
    @State private var listing: FSListing?
    @State private var roots: FSRoots?
    @State private var showHidden = false
    @State private var error: String?
    @State private var naming = false
    @State private var newName = ""

    init(startPath: String, onChoose: @escaping (String) -> Void) {
        self.startPath = startPath
        self.onChoose = onChoose
        _path = State(initialValue: startPath)
    }

    var body: some View {
        List {
            if let roots {
                Section {
                    ScrollView(.horizontal) {
                        HStack(spacing: 8) {
                            ForEach(roots.places) { place in
                                Button(place.name, systemImage: place.name == "Home" ? "house" : "folder") { path = place.path }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                            }
                        }
                    }
                    .scrollIndicators(.hidden)
                    .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                }
            }
            if let listing {
                Section {
                    if let parent = listing.parent {
                        Button {
                            path = parent
                        } label: {
                            Label("Up to \(parent.lastPathComponent.isEmpty ? "/" : parent.lastPathComponent)", systemImage: "arrow.turn.left.up")
                        }
                    }
                    let folders = listing.entries.filter(\.isDirectory)
                    if folders.isEmpty {
                        Text("No folders here.").foregroundStyle(.secondary)
                    }
                    ForEach(folders) { entry in
                        Button {
                            path = entry.path
                        } label: {
                            HStack {
                                Label {
                                    Text(entry.name).foregroundStyle(.primary)
                                } icon: {
                                    Image(systemName: entry.isGitRepo ? "folder.badge.gearshape" : "folder.fill")
                                        .foregroundStyle(entry.isGitRepo ? Color.orange : Color.accentColor)
                                }
                                Spacer()
                                if let modified = entry.modified {
                                    Text(modified, format: .relative(presentation: .numeric, unitsStyle: .narrow))
                                        .font(.footnote).foregroundStyle(.tertiary)
                                }
                            }
                        }
                        .swipeActions {
                            Button("Use", systemImage: "checkmark") { onChoose(entry.path) }.tint(.accentColor)
                        }
                    }
                } header: {
                    HStack {
                        Text(listing.path.abbreviatingHome)
                        if let branch = listing.gitBranch {
                            Label(branch, systemImage: "arrow.triangle.branch").labelStyle(.titleAndIcon)
                        }
                    }
                    .textCase(nil)
                }
            } else if let error {
                ContentUnavailableView("Can't Open Folder", systemImage: "folder.badge.questionmark", description: Text(error))
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
        .navigationTitle(path.lastPathComponent.isEmpty ? "Folders" : path.lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu("More", systemImage: "ellipsis") {
                    Button("New Folder…", systemImage: "folder.badge.plus") { naming = true }
                    Toggle("Show Hidden Folders", systemImage: "eye", isOn: $showHidden)
                }
            }
            ToolbarItem(placement: .bottomBar) {
                Button {
                    onChoose(listing?.path ?? path)
                } label: {
                    Label("Use “\(path.lastPathComponent)”", systemImage: "checkmark.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .disabled(listing == nil)
            }
        }
        .alert("New Folder", isPresented: $naming) {
            TextField("Name", text: $newName)
                .textInputAutocapitalization(.never)
            Button("Create") { Task { await makeFolder() } }
            Button("Cancel", role: .cancel) { newName = "" }
        } message: {
            Text("A new folder inside \(path.lastPathComponent).")
        }
        .task(id: path) { await load() }
        .onChange(of: showHidden) { _, _ in Task { await load() } }
    }

    private func load() async {
        do {
            if roots == nil { roots = try await store.client.request(Method.fsRoots, Empty()) }
            let result: FSListing = try await store.client.request(Method.fsList, FSListParams(path: path, showHidden: showHidden,
                                                                                               directoriesOnly: true))
            listing = result
            error = nil
        } catch {
            listing = nil
            self.error = HubClient.describe(error)
        }
    }

    private func makeFolder() async {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        newName = ""
        guard !name.isEmpty else { return }
        do {
            let entry: FSEntry = try await store.client.request(Method.fsMkdir, FSMkdirParams(parent: listing?.path ?? path, name: name))
            path = entry.path
            store.toast = ToastEvent(message: "Made \(entry.name).", level: "info")
        } catch {
            store.toast = ToastEvent(message: HubClient.describe(error), level: "error")
        }
    }
}
