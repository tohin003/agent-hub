import SwiftUI

/// The conversation, newest at the bottom, following new messages while you're at the end.
struct TimelineList: View {
    var model: SessionModel
    @State private var atBottom = true
    /// Messages that arrived while you were reading further up.
    @State private var unseen = 0

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Theme.rowSpacing) {
                    if model.hasEarlier {
                        Button("Show Earlier Messages", systemImage: "arrow.up.circle") {
                            Task { await model.loadEarlier() }
                        }
                        .buttonStyle(.bordered)
                        .frame(maxWidth: .infinity)
                    }
                    if model.items.isEmpty {
                        TimelineEmpty(model: model)
                    }
                    ForEach(model.items) { item in
                        TimelineRow(item: item, model: model)
                            .id(item.id)
                            .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 10)), removal: .opacity))
                    }
                    WorkingFooter(session: model.session)
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal)
                .padding(.top, 8)
                .animation(.spring(response: 0.42, dampingFraction: 0.86), value: model.items.count)
            }
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.never)
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y + geometry.containerSize.height >= geometry.contentSize.height - 120
            } action: { _, isNearBottom in
                atBottom = isNearBottom
                if isNearBottom { unseen = 0 }
            }
            .onChange(of: model.tailVersion) { _, _ in
                guard atBottom else {
                    unseen += 1
                    return
                }
                withAnimation(.spring(response: 0.45, dampingFraction: 0.9)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .overlay(alignment: .bottomTrailing) {
                if !atBottom {
                    Button {
                        withAnimation(.spring(response: 0.5, dampingFraction: 0.88)) { proxy.scrollTo("bottom", anchor: .bottom) }
                        unseen = 0
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.down")
                            if unseen > 0 {
                                Text("\(unseen) new")
                                    .font(.subheadline.weight(.semibold).monospacedDigit())
                                    .contentTransition(.numericText(value: Double(unseen)))
                            }
                        }
                        .padding(.horizontal, unseen > 0 ? 6 : 0)
                    }
                    .buttonStyle(.glass)
                    .controlSize(.large)
                    .accessibilityLabel(unseen > 0 ? "Jump to the latest, \(unseen) new" : "Jump to the latest")
                    .padding()
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
                    .animation(.spring(response: 0.35, dampingFraction: 0.8), value: unseen)
                }
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: atBottom)
            .sensoryFeedback(.impact(weight: .light), trigger: unseen) { old, new in old == 0 && new > 0 }
        }
    }
}

/// While the agent works: the blob busy with its agents around it, and the agent's own status line.
struct WorkingFooter: View {
    var session: SessionInfo
    @Environment(HubStore.self) private var store

    var body: some View {
        if session.state == .working || session.state == .starting {
            HStack(spacing: 10) {
                BlobView(mood: .working, logos: Account.orbitLogos(store.accounts))
                    .frame(width: 48, height: 48)
                Text(session.stateDetail ?? (session.state == .starting ? "Starting…" : "Working…"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .contentTransition(.numericText())
            }
            .padding(.vertical, 6)
            .accessibilityElement(children: .combine)
        }
    }
}

struct TimelineEmpty: View {
    var model: SessionModel

    var body: some View {
        VStack(spacing: 12) {
            if model.loading {
                ProgressView()
            } else {
                AgentBanner(account: model.account, provider: model.session.provider)
                Text(model.session.transcriptAvailable ? "No messages yet" : "Waiting for the first message")
                    .font(.headline)
                Text("Send a message below. It's typed into the agent's terminal on your Mac.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }
}

/// The agent's whole logo, as its CLI draws it (read by the hub from the CLI's own screen), with its name.
struct AgentBanner: View {
    var account: Account?
    var provider: ProviderKind

    var body: some View {
        VStack(spacing: 10) {
            if let logo = account?.logo, logo.full != logo.mark {
                TerminalArtView(art: TerminalArt(ansi: logo.full))
                    .frame(maxWidth: 240, maxHeight: 70)
                    .padding(16)
                    .background(Color(red: 0.07, green: 0.07, blue: 0.08), in: .rect(cornerRadius: 18))
            } else {
                ProviderGlyph(account: account, provider: provider, size: 84)
            }
            Text(account?.name ?? provider.displayName)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
        }
    }
}
