import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// The message box: what you type is typed into the agent's terminal on the Mac. While the agent works, the stop
/// button interrupts it (Esc). Photos and files go to the Mac first; their path goes into the message.
struct ComposerBar: View {
    var model: SessionModel
    @Binding var showingKeys: Bool
    @Environment(HubStore.self) private var store
    @State private var text = ""
    @State private var sending = false
    @State private var photo: PhotosPickerItem?
    @State private var choosingPhoto = false
    @State private var choosingFile = false
    @State private var uploading = false
    @State private var commands: [SlashCommand] = []
    @State private var sent = 0
    /// Briefly after sending, Send stays where Stop would appear.
    @State private var justSent = false
    @FocusState private var focused: Bool

    private var working: Bool { model.session.state == .working }
    private var ended: Bool { model.session.state == .ended }

    var body: some View {
        VStack(spacing: 8) {
            if !suggestions.isEmpty {
                suggestionList
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            composer
        }
        .animation(.snappy, value: suggestions.isEmpty)
        .sensoryFeedback(.impact(flexibility: .soft, intensity: 0.5), trigger: sent)
        .photosPicker(isPresented: $choosingPhoto, selection: $photo, matching: .images)
        .fileImporter(isPresented: $choosingFile, allowedContentTypes: [.item]) { result in
            switch result {
            case .success(let url): Task { await attachFile(url) }
            case .failure(let error): store.toast = ToastEvent(message: error.localizedDescription, level: "error")
            }
        }
        .onChange(of: photo) { _, item in
            guard let item else { return }
            Task { await attach(item) }
        }
        .task(id: model.session.accountId) {
            commands = await store.slashCommands(model.session.accountId)
        }
    }

    /// The agent's own slash commands that match what's typed after "/", as Claude's app suggests them.
    private var suggestions: [SlashCommand] {
        guard text.hasPrefix("/"), !text.contains(" "), !text.contains("\n") else { return [] }
        let query = text.dropFirst().lowercased()
        let starts = commands.filter { $0.command.dropFirst().lowercased().hasPrefix(query) }
        let contains = query.isEmpty ? [] : commands.filter {
            !$0.command.dropFirst().lowercased().hasPrefix(query) && $0.command.lowercased().contains(query)
        }
        return Array((starts + contains).prefix(40))
    }

    private var suggestionList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(suggestions) { command in
                    Button {
                        text = command.command + " "
                        focused = true
                    } label: {
                        HStack {
                            Text(command.command).font(.body.monospaced())
                            Spacer()
                            if !command.detail.isEmpty {
                                Text(command.detail).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .padding(.horizontal, 16)
                        .frame(minHeight: 44)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    if command.id != suggestions.last?.id { Divider().padding(.leading, 16) }
                }
            }
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(maxHeight: 230)
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
        .accessibilityLabel("Slash commands")
    }

    private var composer: some View {
        GlassEffectContainer(spacing: 8) {
            HStack(alignment: .bottom, spacing: 8) {
                Menu {
                    Section("Attach") {
                        Button("Photo Library", systemImage: "photo.on.rectangle") { choosingPhoto = true }
                        Button("Files", systemImage: "folder") { choosingFile = true }
                    }
                    Section {
                        Button("Slash Command", systemImage: "slash.circle") {
                            text = "/"
                            focused = true
                        }
                    }
                    Section {
                        Button(showingKeys ? "Hide Keys" : "Show Keys", systemImage: "keyboard") { showingKeys.toggle() }
                        if model.session.provider == .claude || model.session.provider == .codex {
                            Button("Switch Mode (⇧Tab)", systemImage: "arrow.triangle.2.circlepath") { Task { await model.keys(["BTab"]) } }
                        }
                    }
                } label: {
                    Image(systemName: "plus")
                        .font(.title3.weight(.medium))
                        .frame(width: 44, height: 44)
                        .contentShape(.circle)
                }
                .accessibilityLabel("Attach, commands and keys")
                .glassEffect(.regular.interactive(), in: .circle)
                .disabled(ended)

                HStack(alignment: .bottom, spacing: 0) {
                    TextField(placeholder, text: $text, axis: .vertical)
                        .lineLimit(1...6)
                        .focused($focused)
                        .disabled(ended)
                        .padding(.leading, 14)
                        .padding(.vertical, 11)
                        .submitLabel(.send)
                    if uploading {
                        ProgressView()
                            .frame(width: 40, height: 44)
                            .accessibilityLabel("Sending the attachment to the Mac")
                    } else {
                        Button("Attach a Photo", systemImage: "photo") { choosingPhoto = true }
                            .labelStyle(.iconOnly)
                            .frame(width: 40, height: 44)
                            .contentShape(.rect)
                            .disabled(ended)
                    }
                    if focused {
                        Button("Hide Keyboard", systemImage: "keyboard.chevron.compact.down") { focused = false }
                            .labelStyle(.iconOnly)
                            .frame(width: 40, height: 44)
                            .contentShape(.rect)
                            .padding(.trailing, 2)
                    }
                }
                .glassEffect(.regular, in: .rect(cornerRadius: 22))

                if working && text.isEmpty && !justSent {
                    Button("Stop", systemImage: "stop.fill") { Task { await model.interrupt() } }
                        .labelStyle(.iconOnly)
                        .font(.title3)
                        .frame(width: 44, height: 44)
                        .glassEffect(.regular.tint(.red).interactive(), in: .circle)
                        .foregroundStyle(.white)
                } else {
                    Button("Send", systemImage: "arrow.up") { Task { await send() } }
                        .symbolEffect(.bounce.up, value: sent)
                        .labelStyle(.iconOnly)
                        .font(.title3.weight(.semibold))
                        .frame(width: 44, height: 44)
                        .glassEffect(.regular.tint(.accentColor).interactive(), in: .circle)
                        .foregroundStyle(Theme.onAccent)
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || sending || ended)
                }
            }
        }
    }

    private var placeholder: String {
        if ended { return "Ended · More › Continue This Conversation" }
        if working { return "Queue for after this turn…" }
        return "Message \(model.account?.name ?? "the agent")"
    }

    private func send() async {
        let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return }
        sending = true
        if await model.send(message) {
            justSent = true
            text = ""
            sent += 1
            Task {
                try? await Task.sleep(for: .seconds(1.2))
                justSent = false
            }
        }
        sending = false
    }

    /// A photo goes to the Mac as a JPEG (at most 2048 pixels across, which agents read well and sends quickly).
    private func attach(_ item: PhotosPickerItem) async {
        defer { photo = nil }
        uploading = true
        defer { uploading = false }
        guard let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) else {
            store.toast = ToastEvent(message: "That photo couldn't be read. If it's in iCloud, wait for it to download and try again.",
                                     level: "error")
            return
        }
        guard let jpeg = Self.scaled(image, maxSide: 2048).jpegData(compressionQuality: 0.8) else { return }
        insert(await model.upload(jpeg, name: "photo.jpg"))
    }

    /// Any file, up to 20 MB, with its own name.
    private func attachFile(_ url: URL) async {
        uploading = true
        defer { uploading = false }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else {
            store.toast = ToastEvent(message: "That file couldn't be read.", level: "error")
            return
        }
        guard data.count <= 20 * 1024 * 1024 else {
            store.toast = ToastEvent(message: "That file is over 20 MB. Put it on the Mac another way and type its path.", level: "error")
            return
        }
        insert(await model.upload(data, name: url.lastPathComponent))
    }

    private func insert(_ path: String?) {
        guard let path else { return }
        text += (text.isEmpty || text.hasSuffix(" ") ? "" : " ") + path + " "
        focused = true
    }

    private static func scaled(_ image: UIImage, maxSide: CGFloat) -> UIImage {
        let side = max(image.size.width, image.size.height)
        guard side > maxSide else { return image }
        let scale = maxSide / side
        let size = CGSize(width: (image.size.width * scale).rounded(), height: (image.size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
    }
}

/// Keys the terminal needs that a phone keyboard doesn't have, drawn as Mac keys.
struct KeyBar: View {
    var model: SessionModel

    private let keys: [MacKey] = [
        .escape, .tab, .shiftTab, .up, .down, .left, .right, .returnKey, .space, .delete,
        .character("1"), .character("2"), .character("3"), .character("0"), .character("y"), .character("n"),
        .control("c"), .control("d"), .control("l"), .control("r"), .control("o"), .pageUp, .pageDown,
    ]

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 7) {
                ForEach(keys) { key in
                    KeyCapButton(key: key, height: 42) {
                        Task { await model.keys(key.terminalKeys) }
                    }
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 4)
        }
        .scrollIndicators(.hidden)
        .padding(.vertical, 2)
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
    }
}
