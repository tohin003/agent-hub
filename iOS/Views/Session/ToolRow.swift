import SwiftUI

/// A tool call as one compact row: what it did, the exact command or file, and how it went. Edits show their
/// diff, to-do lists their items, subagents and background work open into their own view.
struct ToolRow: View {
    var tool: ToolCall
    var model: SessionModel?
    @State private var expanded = false
    @State private var showingDetail = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if let todos = tool.todos, !todos.isEmpty {
                TodoCard(todos: todos)
            }
            if let questions = tool.questions, !questions.isEmpty {
                QuestionCard(questions: questions)
            }
            if let plan = tool.plan, !plan.isEmpty {
                PlanCard(plan: plan)
            }
            if expanded {
                if let subtitle = tool.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.footnote.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(6)
                        .textSelection(.enabled)
                        .padding(.leading, 32)
                }
                if let diff = tool.diff {
                    DiffView(diff: diff, maxLines: 14)
                } else if let output = tool.output, !output.isEmpty {
                    OutputPreview(text: output)
                }
                Button("Details", systemImage: "arrow.up.left.and.arrow.down.right") { showingDetail = true }
                    .font(.footnote)
                    .buttonStyle(.borderless)
            }
        }
        .sheet(isPresented: $showingDetail) {
            ToolDetailView(tool: tool, model: model)
        }
    }

    @ViewBuilder private var header: some View {
        if let model, let agentId = tool.agentId, tool.category == .agent {
            NavigationLink {
                SubagentView(model: model, agentId: agentId, title: tool.title)
            } label: {
                ToolHeader(tool: tool, chevron: true)
            }
            .buttonStyle(.plain)
        } else if let model, let file = tool.outputFile, tool.category == .shell || tool.category == .monitor {
            NavigationLink {
                TaskOutputView(model: model, title: tool.title, path: file, running: tool.status == .background)
            } label: {
                ToolHeader(tool: tool, chevron: true)
            }
            .buttonStyle(.plain)
        } else {
            Button {
                withAnimation(.spring(response: 0.38, dampingFraction: 0.86)) { expanded.toggle() }
            } label: {
                ToolHeader(tool: tool, chevron: false, expanded: expanded)
            }
            .buttonStyle(.press)
            .sensoryFeedback(.selection, trigger: expanded)
        }
    }
}

/// A tool call as one quiet grey line, like Claude's app: "›_ Ran Install the app on the iPhone ›". The agent's
/// own words stay white and stand out; its tools stay in the background until you open them.
struct ToolHeader: View {
    var tool: ToolCall
    var chevron: Bool
    var expanded = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: tool.category.symbol)
                .font(.subheadline)
                .foregroundStyle(iconStyle)
                .frame(width: 22)
                .accessibilityHidden(true)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(title)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(expanded ? 4 : 1)
                    .truncationMode(.tail)
                if let diff = tool.diff, diff.additions + diff.deletions > 0 {
                    Text("+\(diff.additions)").foregroundStyle(.green)
                    Text("−\(diff.deletions)").foregroundStyle(.red)
                }
                status
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(!chevron && expanded ? 90 : 0))
                    .accessibilityHidden(true)
            }
            .font(.footnote.monospacedDigit())
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
        .frame(minHeight: 44)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title), \(statusWord)")
        .accessibilityHint(chevron ? "Opens it" : (expanded ? "Hides the details" : "Shows the details"))
    }

    /// "Ran …" for commands, as Claude's app words it. Agents describe commands in the imperative ("Run the tests"),
    /// so a leading "Run" folds in: "Ran the tests", not "Ran Run the tests".
    private var title: String {
        guard tool.category == .shell else { return tool.title }
        var what = tool.title
        if what.lowercased().hasPrefix("run ") { what = String(what.dropFirst(4)) }
        switch tool.status {
        case .pending: return "Running \(what)"
        case .background: return tool.title
        default: return "Ran \(what)"
        }
    }

    private var iconStyle: AnyShapeStyle {
        switch tool.status {
        case .failed: AnyShapeStyle(Color.red)
        case .denied: AnyShapeStyle(Color.orange)
        default: AnyShapeStyle(.secondary)
        }
    }

    /// Only what needs noticing: running, in the background, failed, not allowed. Done is the quiet default.
    @ViewBuilder private var status: some View {
        switch tool.status {
        case .pending:
            ProgressView().controlSize(.mini)
        case .background:
            Image(systemName: "arrow.triangle.2.circlepath")
                .foregroundStyle(.tint)
                .symbolEffect(.rotate, options: .repeating)
        case .done:
            EmptyView()
        case .failed:
            Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        case .denied:
            Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
        }
    }

    private var statusWord: String {
        switch tool.status {
        case .pending: "running or waiting"
        case .background: "running in the background"
        case .done: "done"
        case .failed: "failed"
        case .denied: "not allowed"
        }
    }
}

struct OutputPreview: View {
    var text: String

    var body: some View {
        Text(text.split(separator: "\n", omittingEmptySubsequences: false).prefix(14).joined(separator: "\n"))
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 10))
            .textSelection(.enabled)
    }
}

struct TodoCard: View {
    var todos: [TodoItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(todos.indices, id: \.self) { index in
                let todo = todos[index]
                Label {
                    Text(todo.content)
                        .strikethrough(todo.status == .completed)
                        .foregroundStyle(todo.status == .completed ? .secondary : .primary)
                        .fontWeight(todo.status == .inProgress ? .semibold : .regular)
                } icon: {
                    Image(systemName: todo.status == .completed ? "checkmark.circle.fill" : (todo.status == .inProgress ? "circle.dotted.circle" : "circle"))
                        .foregroundStyle(todo.status == .pending ? Color.secondary : Color.accentColor)
                        .symbolEffect(.pulse, isActive: todo.status == .inProgress)
                }
                .font(.subheadline)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.fill.quinary, in: .rect(cornerRadius: 14))
    }
}

struct QuestionCard: View {
    var questions: [QuestionSpec]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(questions.indices, id: \.self) { index in
                let question = questions[index]
                VStack(alignment: .leading, spacing: 6) {
                    Text(question.question).font(.subheadline.weight(.semibold))
                    ForEach(question.options.indices, id: \.self) { optionIndex in
                        let option = question.options[optionIndex]
                        VStack(alignment: .leading, spacing: 1) {
                            Text("\(optionIndex + 1). \(option.label)").font(.subheadline)
                            if let detail = option.description {
                                Text(detail).font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            Text("Answer in the card above the message box, or in the terminal.")
                .font(.footnote)
                .foregroundStyle(.tertiary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.fill.quinary, in: .rect(cornerRadius: 14))
    }
}

struct PlanCard: View {
    var plan: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Plan", systemImage: "list.bullet.clipboard").font(.subheadline.weight(.semibold))
            MarkdownView(text: plan)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.fill.quinary, in: .rect(cornerRadius: 14))
    }
}

struct DiffView: View {
    var diff: FileDiff
    var maxLines: Int?

    var body: some View {
        let lines = maxLines.map { Array(diff.lines.prefix($0)) } ?? diff.lines
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label(diff.path.lastPathComponent, systemImage: diff.isNewFile ? "doc.badge.plus" : "doc.text")
                    .font(.caption.weight(.semibold))
                Spacer()
                Text("+\(diff.additions) −\(diff.deletions)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            .padding(8)
            ScrollView(.horizontal) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(lines.indices, id: \.self) { index in
                        let line = lines[index]
                        Text(prefix(line.kind) + line.text)
                            .font(.caption.monospaced())
                            .foregroundStyle(color(line.kind))
                            .padding(.horizontal, 8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(background(line.kind))
                    }
                }
                .fixedSize(horizontal: true, vertical: false)
            }
            if let maxLines, diff.lines.count > maxLines {
                Text("\(diff.lines.count - maxLines) more lines")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(8)
            }
        }
        .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 10))
        .clipShape(.rect(cornerRadius: 10))
    }

    private func prefix(_ kind: DiffLine.Kind) -> String {
        switch kind {
        case .add: "+ "
        case .remove: "− "
        case .context: "  "
        case .hunk: ""
        }
    }

    private func color(_ kind: DiffLine.Kind) -> Color {
        switch kind {
        case .add: Color.green
        case .remove: Color.red
        case .context: Color.primary
        case .hunk: Color.secondary
        }
    }

    private func background(_ kind: DiffLine.Kind) -> Color {
        switch kind {
        case .add: Color.green.opacity(0.1)
        case .remove: Color.red.opacity(0.1)
        default: Color.clear
        }
    }
}
