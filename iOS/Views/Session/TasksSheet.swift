import SwiftUI

/// Everything running in the background of a session: subagents, forks, shells, monitors, workflows.
struct TasksSheet: View {
    var model: SessionModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                let running = model.tasks.filter { $0.status == .running }
                let finished = model.tasks.filter { $0.status != .running }
                if model.tasks.isEmpty {
                    ContentUnavailableView("Nothing in the Background", systemImage: "gearshape.2",
                                           description: Text("Subagents, background shells, monitors and workflows this agent starts appear here, live."))
                }
                if !running.isEmpty {
                    Section("Running") { ForEach(running) { row($0) } }
                }
                if !finished.isEmpty {
                    Section("Finished") { ForEach(finished.reversed()) { row($0) } }
                }
            }
            .navigationTitle("Background")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", systemImage: "checkmark") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    @ViewBuilder
    private func row(_ task: BackgroundTask) -> some View {
        if let agentId = task.agentId, task.kind == .agent || task.kind == .fork {
            NavigationLink {
                SubagentView(model: model, agentId: agentId, title: task.title)
            } label: {
                TaskRow(task: task)
            }
        } else if let file = task.outputFile {
            NavigationLink {
                TaskOutputView(model: model, title: task.title, path: file, running: task.status == .running)
            } label: {
                TaskRow(task: task)
            }
        } else {
            TaskRow(task: task)
        }
    }
}

struct TaskRow: View {
    var task: BackgroundTask

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: task.kind.symbol)
                .foregroundStyle(task.status.tint)
                .frame(width: 30, height: 30)
                .background(task.status.tint.opacity(0.12), in: .circle)
                .symbolEffect(.pulse, isActive: task.status == .running)
            VStack(alignment: .leading, spacing: 3) {
                Text(task.title).font(.subheadline.weight(.medium)).lineLimit(2)
                HStack(spacing: 6) {
                    Text(task.kind.title)
                    Text("·")
                    Text(task.status.title).foregroundStyle(task.status.tint)
                    if let started = task.startedAt, task.status == .running {
                        Text("·")
                        Text(started, style: .timer).monospacedDigit()
                    }
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                if let detail = task.detail, !detail.isEmpty {
                    Text(detail).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(2)
                }
                if let summary = task.summary, task.status != .running {
                    Text(summary).font(.footnote).foregroundStyle(.secondary).lineLimit(3)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

/// A subagent's (or fork's) own conversation, followed live while it runs.
struct SubagentView: View {
    @Environment(HubStore.self) private var store
    var model: SessionModel
    var agentId: String
    var title: String
    @State private var items: [TimelineItem] = []
    @State private var version = 0
    @State private var finished = false
    @State private var error: String?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Theme.rowSpacing) {
                if items.isEmpty, error == nil {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
                }
                if let error {
                    ContentUnavailableView("Not Available Yet", systemImage: "person.2", description: Text(error))
                }
                ForEach(items) { item in
                    SubagentRow(item: item, model: model, agentId: agentId)
                }
                if !finished, error == nil, !items.isEmpty {
                    HStack(spacing: 8) {
                        BlobView(mood: .working, logos: Account.orbitLogos(store.accounts)).frame(width: 44, height: 44)
                        Text("Working…").font(.subheadline).foregroundStyle(.secondary)
                    }
                }
            }
            .padding()
        }
        .defaultScrollAnchor(.bottom)
        .navigationTitle(title)
        .navigationSubtitle(finished ? "Finished" : "Running")
        .navigationBarTitleDisplayMode(.inline)
        .task { await follow() }
    }

    private func follow() async {
        while !Task.isCancelled {
            do {
                let result = try await model.subagent(agentId, since: version)
                if version == 0 {
                    items = result.items
                } else {
                    for item in result.items {
                        if let index = items.firstIndex(where: { $0.id == item.id }) { items[index] = item } else { items.append(item) }
                    }
                }
                version = result.version
                finished = result.finished
                error = nil
            } catch {
                self.error = HubClient.describe(error)
            }
            try? await Task.sleep(for: .seconds(finished ? 6 : 1.5))
        }
    }
}

/// A subagent's tool rows open their details from the subagent's own conversation.
struct SubagentRow: View {
    var item: TimelineItem
    var model: SessionModel
    var agentId: String

    var body: some View {
        if item.kind == .tool, let tool = item.tool {
            SubagentToolRow(tool: tool, model: model, agentId: agentId)
        } else {
            TimelineRow(item: item, model: nil)
        }
    }
}

struct SubagentToolRow: View {
    var tool: ToolCall
    var model: SessionModel
    var agentId: String
    @State private var showing = false

    var body: some View {
        Button {
            showing = true
        } label: {
            ToolHeader(tool: tool, chevron: true)
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showing) {
            ToolDetailView(tool: tool, model: model, agentId: agentId)
        }
    }
}

/// A background shell's or monitor's output, following the file as it grows.
struct TaskOutputView: View {
    var model: SessionModel
    var title: String
    var path: String
    var running: Bool
    @State private var text = ""
    @State private var offset: Int64 = -1
    @State private var truncated = false
    @State private var error: String?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView([.vertical, .horizontal]) {
                VStack(alignment: .leading, spacing: 8) {
                    if truncated {
                        Text("Showing the end of the output.").font(.caption).foregroundStyle(.secondary)
                    }
                    if let error {
                        Text(error).font(.callout).foregroundStyle(.secondary)
                    }
                    Text(text.isEmpty && error == nil ? "No output yet." : text)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .fixedSize(horizontal: true, vertical: false)
                    Color.clear.frame(height: 1).id("end")
                }
                .padding()
            }
            .onChange(of: text) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
        }
        .navigationTitle(title)
        .navigationSubtitle(path.lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                ShareLink(item: text)
            }
        }
        .task { await follow() }
    }

    private func follow() async {
        while !Task.isCancelled {
            do {
                let result = try await model.taskOutput(path: path, offset: offset)
                if offset < 0 {
                    text = result.text
                    truncated = result.truncatedStart
                } else if !result.text.isEmpty {
                    text += result.text
                    if text.count > 400_000 {
                        text = String(text.suffix(300_000))
                        truncated = true
                    }
                }
                offset = result.offset
                error = nil
            } catch {
                self.error = HubClient.describe(error)
            }
            try? await Task.sleep(for: .seconds(running ? 1.5 : 10))
        }
    }
}
