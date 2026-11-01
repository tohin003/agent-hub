import SwiftUI

/// One timeline entry, drawn the way Claude's app draws it: your messages in bubbles, the agent's replies as
/// text, tools as compact rows you can open.
struct TimelineRow: View {
    var item: TimelineItem
    var model: SessionModel?

    var body: some View {
        switch item.kind {
        case .user:
            UserBubble(text: item.text ?? "", attachments: item.attachments ?? [])
        case .assistant:
            MarkdownView(text: item.text ?? "")
                .frame(maxWidth: .infinity, alignment: .leading)
        case .thinking:
            ThinkingRow(text: item.text ?? "")
        case .tool:
            if let tool = item.tool { ToolRow(tool: tool, model: model) }
        case .system:
            SystemNote(text: item.text ?? "", level: item.level ?? "info")
        case .task:
            TaskNote(text: item.text ?? "", level: item.level ?? "info")
        case .command:
            CommandRow(text: item.text ?? "")
        }
    }
}

struct UserBubble: View {
    var text: String
    var attachments: [String]

    var body: some View {
        HStack {
            Spacer(minLength: 48)
            VStack(alignment: .trailing, spacing: 6) {
                if !attachments.isEmpty {
                    Label("\(attachments.count) image\(attachments.count == 1 ? "" : "s")", systemImage: "photo")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if !text.isEmpty {
                    Text(Markdown.inline(text))
                        .font(.body)
                        .textSelection(.enabled)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(Color(.secondarySystemFill), in: UnevenRoundedRectangle(
                            topLeadingRadius: Theme.bubbleRadius, bottomLeadingRadius: Theme.bubbleRadius,
                            bottomTrailingRadius: 6, topTrailingRadius: Theme.bubbleRadius))
                }
            }
        }
        .padding(.vertical, 4)
    }
}

struct ThinkingRow: View {
    var text: String
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            Text(text)
                .font(.callout)
                .italic()
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)
        } label: {
            Label("Thinking", systemImage: "brain")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .tint(.secondary)
    }
}

struct SystemNote: View {
    var text: String
    var level: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
            Text(text)
                .lineLimit(level == "recap" ? 6 : 3)
        }
        .font(.footnote)
        .foregroundStyle(level == "error" ? Color.red : (level == "warning" ? Color.orange : Color.secondary))
        .frame(maxWidth: .infinity, alignment: level == "recap" ? .leading : .center)
        .padding(.vertical, 4)
    }

    private var symbol: String {
        switch level {
        case "error": "exclamationmark.triangle"
        case "warning": "exclamationmark.circle"
        case "turn": "clock"
        case "recap": "text.quote"
        default: "info.circle"
        }
    }
}

struct TaskNote: View {
    var text: String
    var level: String

    var body: some View {
        Label(text, systemImage: level == "warning" ? "xmark.circle" : "checkmark.circle")
            .font(.footnote)
            .foregroundStyle(level == "warning" ? Color.orange : Color.secondary)
            .padding(.vertical, 2)
    }
}

struct CommandRow: View {
    var text: String

    var body: some View {
        let lines = text.components(separatedBy: "\n")
        VStack(alignment: .leading, spacing: 4) {
            Text(lines.first ?? "")
                .font(.callout.monospaced().weight(.semibold))
                .foregroundStyle(.tint)
            if lines.count > 1 {
                Text(lines.dropFirst().joined(separator: "\n"))
                    .font(.footnote.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(14)
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.fill.quinary, in: .rect(cornerRadius: 12))
    }
}
