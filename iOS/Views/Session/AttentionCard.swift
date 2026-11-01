import SwiftUI

/// The choice the agent is waiting on, with exactly what its terminal offers:
/// - choices: tap to choose (the cursor moves there and Return is pressed);
/// - a choice that takes your own words ("Type something."): type them here, they're typed there;
/// - checklists: tap a box to tick or untick it (Space), then tap the action ("Enable selected") to confirm;
/// - sliders (Claude Code's effort): the levels side by side;
/// - the keys the dialog names ("Space to select", "s to use this session only", "←/→ to adjust") as buttons;
/// - and always ▲ ▼ space return esc, so no dialog can leave you stuck.
/// An answer is only sent while the same question is still on the Mac's screen.
struct AttentionCard: View {
    var prompt: AttentionPrompt
    var model: SessionModel
    @State private var showContext: Bool
    @State private var working: Int?
    @State private var answered = 0
    @State private var typed = ""
    @FocusState private var typing: Bool

    init(prompt: AttentionPrompt, model: SessionModel) {
        self.prompt = prompt
        self.model = model
        // Short details (a command, a file) show at once; long ones wait for a tap.
        _showContext = State(initialValue: (prompt.context?.split(separator: "\n").count ?? 0) <= 5)
    }

    private var isOptional: Bool { prompt.optional == true }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: symbol)
                    .foregroundStyle(isOptional ? Color.secondary : Color.orange)
                Text(prompt.question)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(5)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            if let context = prompt.context, !context.isEmpty {
                DisclosureGroup(isExpanded: $showContext) {
                    ScrollView {
                        Text(context)
                            .font(.caption.monospaced())
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(maxHeight: 150)
                    .padding(8)
                    .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 10))
                } label: {
                    Text("Details").font(.footnote).foregroundStyle(.secondary)
                }
            }
            if prompt.horizontal == true {
                sideBySide
            } else if isOptional {
                HStack(spacing: 8) {
                    ForEach(prompt.options) { option in
                        Button(option.label) { Task { await answer(option, key: nil) } }
                            .buttonStyle(.bordered)
                            .disabled(working != nil)
                    }
                }
            } else {
                VStack(spacing: 6) {
                    ForEach(prompt.options) { option in
                        if option.isToggle {
                            toggleRow(option)
                        } else if option.takesText == true {
                            textRow(option)
                        } else {
                            choiceRow(option)
                        }
                    }
                }
            }
            if let footer = prompt.footer, !footer.isEmpty {
                Text(footer)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let actions = prompt.keyActions, !actions.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(actions) { action in
                            Button {
                                Task { await model.keys(action.keys) }
                            } label: {
                                HStack(spacing: 6) {
                                    KeyCapLabel(key: MacKey.named(action.keyName, keys: action.keys), height: 30)
                                        .scaleEffect(0.85)
                                    Text(action.label).font(.footnote.weight(.medium))
                                }
                                .padding(.trailing, 8)
                                .frame(minHeight: 44)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("\(action.label), \(action.keyName)")
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }
            if !isOptional {
                DisclosureGroup {
                    HStack(spacing: 6) {
                        ForEach(prompt.horizontal == true ? [MacKey.left, .right, .returnKey, .escape]
                                    : [MacKey.up, .down, .space, .returnKey, .escape]) { key in
                            KeyCapButton(key: key, height: 44) {
                                Task { await model.keys(key.terminalKeys) }
                            }
                        }
                    }
                    .padding(.top, 4)
                } label: {
                    Text("Keys").font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        .padding(14)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
        .sensoryFeedback(.success, trigger: answered)
    }

    private var symbol: String {
        if isOptional { return "bubble.left" }
        if prompt.horizontal == true { return "slider.horizontal.3" }
        return prompt.multiSelect == true ? "checklist" : "hand.raised.fill"
    }

    /// A slider's levels, side by side; the current one is filled.
    private var sideBySide: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(prompt.options) { option in
                    let current = option.index == prompt.selectedIndex
                    Button {
                        Task { await answer(option, key: "Enter") }
                    } label: {
                        HStack(spacing: 4) {
                            if working == option.index { ProgressView().controlSize(.mini) }
                            Text(option.label).font(.subheadline.weight(current ? .semibold : .regular))
                        }
                        .padding(.horizontal, 14)
                        .frame(minHeight: 44)
                        .background(current ? Color.accentColor.opacity(0.22) : Color(.tertiarySystemFill), in: .capsule)
                    }
                    .buttonStyle(.plain)
                    .disabled(working != nil)
                    .accessibilityAddTraits(current ? .isSelected : [])
                }
            }
        }
        .scrollIndicators(.hidden)
    }

    /// A choice or an action ("Enable selected"): moves the cursor there and presses Return.
    private func choiceRow(_ option: AttentionOption) -> some View {
        Button {
            Task { await answer(option, key: "Enter") }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.label)
                        .font(.subheadline.weight(option.isAction == true || option.index == 1 ? .semibold : .regular))
                        .multilineTextAlignment(.leading)
                    if let detail = option.detail {
                        Text(detail).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                    }
                }
                Spacer()
                if working == option.index {
                    ProgressView().controlSize(.small)
                } else if option.isCurrent == true {
                    Image(systemName: "checkmark").foregroundStyle(.tint).accessibilityLabel("Current")
                } else if option.isAction == true {
                    Image(systemName: "return").foregroundStyle(.tint).accessibilityHidden(true)
                } else if option.index == prompt.selectedIndex {
                    Image(systemName: "chevron.right.circle.fill").foregroundStyle(.tint).accessibilityLabel("Highlighted")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .background(background(option), in: .rect(cornerRadius: 12))
        }
        .buttonStyle(.press)
        .foregroundStyle(option.isNegative ? Color.red : Color.primary)
        .disabled(working != nil)
    }

    /// "Type something.": your own answer, typed into that choice on the Mac and submitted.
    private func textRow(_ option: AttentionOption) -> some View {
        HStack(spacing: 8) {
            TextField(option.label, text: $typed, axis: .vertical)
                .lineLimit(1...4)
                .focused($typing)
                .submitLabel(.send)
                .onSubmit { Task { await sendTyped(option) } }
            if working == option.index {
                ProgressView().controlSize(.small)
            } else {
                Button("Send", systemImage: "arrow.up.circle.fill") { Task { await sendTyped(option) } }
                    .labelStyle(.iconOnly)
                    .font(.title2)
                    .disabled(typed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .background(Color(.tertiarySystemFill), in: .rect(cornerRadius: 12))
        .disabled(working != nil)
    }

    /// A checklist item: tapping ticks or unticks it (Space), and the list stays open.
    private func toggleRow(_ option: AttentionOption) -> some View {
        Button {
            Task { await answer(option, key: "Space") }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: option.checked == true ? "checkmark.square.fill" : "square")
                    .font(.title3)
                    .foregroundStyle(option.checked == true ? Color.accentColor : Color.secondary)
                    .contentTransition(.symbolEffect(.replace))
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.label).font(.subheadline).multilineTextAlignment(.leading)
                    if let detail = option.detail {
                        Text(detail).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                    }
                }
                Spacer()
                if working == option.index {
                    ProgressView().controlSize(.small)
                } else if option.index == prompt.selectedIndex {
                    Image(systemName: "chevron.right.circle.fill").foregroundStyle(.tint).accessibilityLabel("Highlighted")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .background(Color(.tertiarySystemFill), in: .rect(cornerRadius: 12))
        }
        .buttonStyle(.press)
        .accessibilityValue(option.checked == true ? "Selected" : "Not selected")
        .accessibilityHint("Ticks or unticks it on the Mac")
        .disabled(working != nil)
    }

    private func background(_ option: AttentionOption) -> Color {
        if option.isNegative { return Color.red.opacity(0.08) }
        if option.isAction == true { return Color.accentColor.opacity(0.16) }
        return option.index == 1 ? Color.accentColor.opacity(0.14) : Color(.tertiarySystemFill)
    }

    private func answer(_ option: AttentionOption, key: String?) async {
        working = option.index
        if await model.answer(prompt, option: option, key: key), key != "Space" { answered += 1 }
        working = nil
    }

    private func sendTyped(_ option: AttentionOption) async {
        let text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        working = option.index
        if await model.answer(prompt, option: option, text: text) {
            typed = ""
            typing = false
            answered += 1
        }
        working = nil
    }
}
