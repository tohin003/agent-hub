import SwiftUI

/// How full the context window is, as a small ring for the toolbar (like Claude's app). Tap for usage.
struct ContextRing: View {
    var percent: Double?

    var body: some View {
        ZStack {
            if let percent {
                Circle().stroke(Color.secondary.opacity(0.3), lineWidth: 2.5)
                Circle()
                    .trim(from: 0, to: min(1, max(0.02, percent / 100)))
                    .stroke(tint, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            } else {
                // Not known yet (before the agent's first reply): dashed, so it doesn't read as 0%.
                Circle().stroke(Color.secondary.opacity(0.55), style: StrokeStyle(lineWidth: 2, dash: [2.5, 3]))
            }
        }
        .frame(width: 20, height: 20)
        .animation(.snappy, value: percent)
    }

    private var tint: Color {
        guard let percent else { return .secondary }
        if percent >= 90 { return .red }
        if percent >= 75 { return .orange }
        return .accentColor
    }
}

/// Context, plan limits and what's using them, as the agent reports them: Claude Code's status line and `/usage`,
/// Codex's own logs, OpenCode's records.
struct UsageSheet: View {
    var model: SessionModel
    @Environment(HubStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var account: AccountUsage?
    @State private var loading = false
    @State private var problem: String?
    @State private var showingBreakdown = false

    private var usage: SessionUsage? { model.session.usage }
    private var provider: ProviderKind { model.session.provider }
    private var reportsPlan: Bool { provider == .claude || provider == .codex }

    var body: some View {
        NavigationStack {
            List {
                Section("Context") {
                    contextRow
                }
                if let limits = planLimits, !limits.isEmpty {
                    Section {
                        ForEach(limits) { limit in
                            LimitRow(limit: limit)
                        }
                    } header: {
                        Text("Plan usage")
                    } footer: {
                        if let notes = account?.notes, !notes.isEmpty {
                            Text(notes.joined(separator: "\n"))
                        }
                    }
                } else if reportsPlan {
                    Section("Plan usage") {
                        if loading {
                            HStack(spacing: 10) {
                                ProgressView()
                                Text("Asking \(model.account?.name ?? "the agent")…").foregroundStyle(.secondary)
                            }
                        } else {
                            Text(problem ?? "No plan limits reported yet.").foregroundStyle(.secondary)
                        }
                    }
                }
                if let sections = account?.sections, !sections.isEmpty {
                    ForEach(sections) { section in
                        Section {
                            ForEach(section.lines) { line in
                                InsightRow(line: line)
                            }
                        } header: {
                            Text(section.title)
                        }
                    }
                }
                if provider == .opencode, let cost = usage?.costUSD, cost > 0 {
                    Section("Cost") {
                        LabeledContent("Last reply", value: cost, format: .currency(code: "USD"))
                    }
                }
            }
            .navigationTitle("Usage")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark") { dismiss() }
                }
                if reportsPlan {
                    ToolbarItem(placement: .primaryAction) {
                        Button("Refresh", systemImage: "arrow.clockwise") { Task { await load(refresh: true) } }
                            .disabled(loading)
                    }
                }
            }
            .task { await load(refresh: false) }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    /// The account's own report when it has one (more complete), else what the session itself reported.
    private var planLimits: [UsageLimit]? {
        if let limits = account?.limits, !limits.isEmpty { return limits }
        if let limits = usage?.limits, !limits.isEmpty { return limits }
        return nil
    }

    @ViewBuilder private var contextRow: some View {
        if let usage, let tokens = usage.contextTokens {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Context window")
                    Spacer()
                    if let percent = usage.contextPercent {
                        Text("\(Int(percent.rounded()))% used")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .contentTransition(.numericText(value: percent))
                            .animation(.snappy, value: percent)
                    }
                }
                if let percent = usage.contextPercent {
                    UsageBar(percent: percent, tint: percent >= 90 ? .red : (percent >= 75 ? .orange : .accentColor))
                }
                Text(tokenLine(tokens, window: usage.contextWindow))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
            .accessibilityElement(children: .combine)
        } else {
            Text(provider.hasStructuredTranscript ? "Shows after the agent's first reply." : "\(model.account?.name ?? "This agent") doesn't report its context.")
                .foregroundStyle(.secondary)
        }
    }

    private func tokenLine(_ tokens: Int, window: Int?) -> String {
        let used = tokens.formatted(.number.notation(.compactName).precision(.fractionLength(0...1)))
        guard let window else { return "\(used) tokens" }
        return "\(used) of \(window.formatted(.number.notation(.compactName))) tokens"
    }

    private func load(refresh: Bool) async {
        guard reportsPlan, !loading else { return }
        loading = true
        problem = nil
        defer { loading = false }
        do {
            account = try await store.accountUsage(model.session.accountId, refresh: refresh)
        } catch {
            problem = HubClient.describe(error)
        }
    }
}

struct UsageBar: View {
    var percent: Double
    var tint: Color

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(tint.opacity(0.18))
                Capsule().fill(tint).frame(width: max(4, proxy.size.width * min(1, percent / 100)))
            }
        }
        .frame(height: 6)
        .accessibilityHidden(true)
    }
}

struct LimitRow: View {
    var limit: UsageLimit

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(limit.name)
                Spacer()
                Text("\(Int(limit.percent.rounded()))% used")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .contentTransition(.numericText(value: limit.percent))
            }
            UsageBar(percent: limit.percent, tint: limit.percent >= 90 ? .red : (limit.percent >= 75 ? .orange : .blue))
            if let reset = resetText {
                Text(reset).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    private var resetText: String? {
        if let date = limit.resetsAt {
            let calendar = Calendar.current
            if calendar.isDateInToday(date) { return "Resets at \(date.formatted(date: .omitted, time: .shortened))" }
            if date.timeIntervalSinceNow < 6 * 86_400 {
                return "Resets \(date.formatted(.dateTime.weekday(.abbreviated).hour().minute()))"
            }
            return "Resets \(date.formatted(date: .abbreviated, time: .shortened))"
        }
        guard let text = limit.resetsText else { return nil }
        // "reset since Codex's last turn" reads on its own; "Nov 1 at 10:30pm" needs "Resets".
        return text.lowercased().hasPrefix("reset") ? text.prefix(1).uppercased() + text.dropFirst() : "Resets \(text)"
    }
}

/// "90%  Start fresh when you switch tasks · run /clear".
struct InsightRow: View {
    var line: UsageLine

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            if let percent = line.percent {
                Text("\(Int(percent.rounded()))%")
                    .font(.subheadline.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 40, alignment: .trailing)
            }
            Text(line.text).font(.subheadline)
        }
    }
}

/// The model and effort under the message box ("Opus 5.5 · Max"). Tap to choose.
struct ModelPill: View {
    var model: SessionModel
    @Binding var showingModels: Bool

    var body: some View {
        Button {
            showingModels = true
        } label: {
            HStack(spacing: 4) {
                Text(name).foregroundStyle(.primary)
                if let effort = model.session.usage?.effort {
                    Text(effort.capitalized).foregroundStyle(.secondary)
                }
                Image(systemName: "chevron.up.chevron.down").font(.caption2).foregroundStyle(.secondary)
            }
            .font(.footnote.weight(.medium))
            .padding(.horizontal, 12)
            .frame(minHeight: 36)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .capsule)
        .padding(.vertical, 4)
        .contentShape(.rect)
        .accessibilityLabel("Model: \(name)\(model.session.usage?.effort.map { ", \($0) effort" } ?? "")")
        .accessibilityHint("Choose the model and effort")
    }

    private var name: String {
        if let name = model.session.usage?.modelName { return name }
        guard let id = model.session.model else { return "Model" }
        // The agent's own name for it when its model list has it (Codex: "gpt-6.1-sol" → "GPT-6.1-Sol").
        if let option = store.catalogs[model.session.accountId]?.options.first(where: { $0.slug == id }) { return option.label }
        return ModelNames.readable(id)
    }

    @Environment(HubStore.self) private var store
}

/// The models the agent offers, read from its own picker (Claude Code) or model cache (Codex), and its effort
/// levels. Choosing one drives the agent's own picker on the Mac, for this session only.
struct ModelSheet: View {
    var model: SessionModel
    @Environment(HubStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var catalog: ModelCatalog?
    @State private var loading = false
    @State private var problem: String?
    @State private var working: String?

    private var currentName: String? { model.session.usage?.modelName ?? model.session.model.map(ModelNames.readable) }
    private var currentEffort: String? { model.session.usage?.effort?.lowercased() }

    var body: some View {
        NavigationStack {
            List {
                if let catalog {
                    Section {
                        ForEach(catalog.options) { option in
                            Button {
                                Task { await choose(option, effort: nil) }
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(option.label).foregroundStyle(.primary)
                                        if let detail = option.detail {
                                            Text(detail).font(.footnote).foregroundStyle(.secondary)
                                        }
                                    }
                                    Spacer()
                                    if working == "model-\(option.number)" {
                                        ProgressView()
                                    } else if isCurrent(option) {
                                        Image(systemName: "checkmark").foregroundStyle(.tint).accessibilityLabel("Current")
                                    }
                                }
                                .contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                            .disabled(working != nil)
                        }
                    } footer: {
                        Text("Applies to this session. Read from \(model.account?.name ?? "the agent")'s own model list.")
                    }
                    let levels = effortLevels(catalog)
                    if !levels.isEmpty {
                        Section("Effort") {
                            Picker("Effort", selection: effortBinding(levels)) {
                                ForEach(levels, id: \.self) { level in
                                    Text(level.capitalized).tag(level)
                                }
                            }
                            .pickerStyle(.navigationLink)
                            .disabled(working != nil)
                            if working == "effort" {
                                HStack(spacing: 8) {
                                    ProgressView()
                                    Text("Setting the effort on the Mac…").foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                } else if loading {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Reading \(model.account?.name ?? "the agent")'s models…").foregroundStyle(.secondary)
                    }
                } else {
                    Text(problem ?? "No models.").foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Select model")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Read Again", systemImage: "arrow.clockwise") { Task { await load(refresh: true) } }
                        .disabled(loading || working != nil)
                }
            }
            .task { await load(refresh: false) }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func isCurrent(_ option: ModelOption) -> Bool {
        if let currentName { return option.label.caseInsensitiveCompare(currentName) == .orderedSame }
        if let slug = option.slug, let id = model.session.model { return slug == id }
        return false
    }

    /// The current model's own levels when the list knows them, else the agent's.
    private func effortLevels(_ catalog: ModelCatalog) -> [String] {
        let current = catalog.options.first(where: isCurrent)
        if let levels = current?.effortLevels { return levels }
        return catalog.effortLevels
    }

    /// The effort the session reports; none selected when it hasn't said (never a guess).
    private func effortBinding(_ levels: [String]) -> Binding<String> {
        Binding {
            currentEffort.flatMap { effort in levels.first { $0.lowercased() == effort } } ?? ""
        } set: { level in
            guard !level.isEmpty else { return }
            Task { await chooseEffort(level) }
        }
    }

    private func load(refresh: Bool) async {
        loading = true
        problem = nil
        defer { loading = false }
        do {
            catalog = try await store.modelCatalog(model.session.accountId, refresh: refresh)
        } catch {
            problem = HubClient.describe(error)
        }
    }

    private func choose(_ option: ModelOption, effort: String?) async {
        guard working == nil, !isCurrent(option) else { return }
        working = "model-\(option.number)"
        let done = await model.setModel(option, effort: effort)
        working = nil
        if done { dismiss() }
    }

    private func chooseEffort(_ level: String) async {
        guard working == nil, level.lowercased() != currentEffort else { return }
        working = "effort"
        let current = catalog?.options.first(where: isCurrent)
        _ = await model.setModel(model.session.provider == .codex ? current : nil, effort: level)
        working = nil
    }
}
