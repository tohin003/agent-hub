import SwiftUI

/// The agent's reply, laid out as Markdown blocks with system text styles.
struct MarkdownView: View {
    var text: String
    @State private var blocks: [MarkdownBlock] = []
    @State private var parsedFor = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(currentBlocks) { block in
                MarkdownBlockView(block: block)
            }
        }
        .textSelection(.enabled)
        .onChange(of: text, initial: true) { _, new in
            guard new != parsedFor else { return }
            parsedFor = new
            blocks = Markdown.parse(new)
        }
    }

    /// Parsed on first draw too, so a reply never flashes empty.
    private var currentBlocks: [MarkdownBlock] {
        parsedFor == text ? blocks : Markdown.parse(text)
    }
}

struct MarkdownBlockView: View {
    var block: MarkdownBlock

    var body: some View {
        switch block {
        case .heading(let level, let text, _):
            Text(text)
                .font(level == 1 ? .title2.bold() : (level == 2 ? .title3.bold() : .headline))
                .padding(.top, level <= 2 ? 6 : 2)
        case .paragraph(let text, _):
            Text(text)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
        case .list(let items, _, _):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(items.indices, id: \.self) { index in
                    let item = items[index]
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        if let checked = item.checked {
                            Image(systemName: checked ? "checkmark.square.fill" : "square")
                                .foregroundStyle(checked ? Color.accentColor : Color.secondary)
                        } else {
                            Text(item.marker)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        Text(item.text)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.leading, Double(item.indent) * 16)
                }
            }
        case .code(let language, let text, _):
            CodeBlock(language: language, text: text)
        case .quote(let text, _):
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 2).fill(.tint.opacity(0.5)).frame(width: 3)
                Text(text).foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        case .table(let header, let rows, _):
            ScrollView(.horizontal) {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
                    GridRow {
                        ForEach(header.indices, id: \.self) { column in
                            Text(header[column]).font(.subheadline.bold())
                        }
                    }
                    Divider()
                    ForEach(rows.indices, id: \.self) { row in
                        GridRow {
                            ForEach(rows[row].indices, id: \.self) { column in
                                Text(rows[row][column]).font(.subheadline)
                            }
                        }
                    }
                }
                .padding(12)
            }
            .background(.fill.quinary, in: .rect(cornerRadius: 12))
        case .rule:
            Divider()
        }
    }
}

struct CodeBlock: View {
    var language: String?
    var text: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language ?? "code")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                Spacer()
                Button(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc") {
                    UIPasteboard.general.string = text
                    copied = true
                }
                .labelStyle(.iconOnly)
                .font(.caption)
                .buttonStyle(.borderless)
                .frame(minWidth: 44, minHeight: 32)
            }
            .padding(.leading, 12)
            ScrollView(.horizontal) {
                Text(text)
                    .font(.callout.monospaced())
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .scrollIndicators(.hidden)
        }
        .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 12))
        .sensoryFeedback(.success, trigger: copied) { _, new in new }
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
    }
}
