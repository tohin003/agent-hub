import SwiftUI

/// Everything about one tool call: the full input, the full output, the whole diff.
struct ToolDetailView: View {
    var tool: ToolCall
    var model: SessionModel?
    var agentId: String?
    @Environment(\.dismiss) private var dismiss
    @State private var full: ToolCall?

    private var shown: ToolCall { full ?? tool }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("Tool", value: shown.name)
                    LabeledContent("Result") {
                        Text(statusText).foregroundStyle(shown.status == .failed ? .red : .secondary)
                    }
                    if let duration = shown.durationMs {
                        LabeledContent("Took", value: Duration.milliseconds(duration).formatted(.units(allowed: [.minutes, .seconds, .milliseconds], width: .abbreviated, maximumUnitCount: 2)))
                    }
                    if let code = shown.exitCode {
                        LabeledContent("Exit code", value: "\(code)")
                    }
                }
                if let subtitle = shown.subtitle, !subtitle.isEmpty {
                    Section(shown.category == .shell ? "Command" : "Target") {
                        Text(subtitle).font(.callout.monospaced()).textSelection(.enabled)
                    }
                }
                if let diff = shown.diff {
                    Section("Changes") {
                        DiffView(diff: diff, maxLines: nil)
                            .listRowInsets(EdgeInsets())
                    }
                }
                if let todos = shown.todos {
                    Section("To-dos") { TodoCard(todos: todos).listRowInsets(EdgeInsets()) }
                }
                if let input = shown.input, !input.isEmpty {
                    Section("Input") {
                        Text(input).font(.caption.monospaced()).textSelection(.enabled)
                    }
                }
                if let output = shown.output, !output.isEmpty {
                    Section("Output") {
                        Text(output).font(.caption.monospaced()).textSelection(.enabled)
                    }
                }
            }
            .navigationTitle(tool.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", systemImage: "checkmark") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    ShareLink(item: [shown.subtitle, shown.input, shown.output].compactMap { $0 }.joined(separator: "\n\n"))
                }
            }
            .task {
                if let model { full = await model.fullTool(tool.id, agentId: agentId) }
            }
        }
    }

    private var statusText: String {
        switch shown.status {
        case .pending: "Running or waiting"
        case .background: "Running in the background"
        case .done: "Done"
        case .failed: "Failed"
        case .denied: "Not allowed"
        }
    }
}
