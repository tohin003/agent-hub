import SwiftUI

/// Another session needs you while you're in the app: a glass banner drops in from the top with the agent, its question
/// and folder. Tap to open the session, swipe it up to put it away; it leaves on its own after a few seconds.
struct InAppAlertBanner: View {
    @Environment(HubStore.self) private var store
    @State private var drag: CGFloat = 0
    @State private var shown: InAppAlert?

    var body: some View {
        ZStack {
            if let alert = shown {
                content(alert)
                    .offset(y: min(0, drag))
                    .gesture(
                        DragGesture(minimumDistance: 4)
                            .onChanged { drag = $0.translation.height }
                            .onEnded { value in
                                if value.translation.height < -24 || value.predictedEndTranslation.height < -60 {
                                    dismiss()
                                } else {
                                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { drag = 0 }
                                }
                            }
                    )
                    .transition(.asymmetric(insertion: .move(edge: .top).combined(with: .opacity),
                                            removal: .move(edge: .top).combined(with: .opacity)))
                    .id(alert.id)
            }
        }
        .animation(.spring(response: 0.42, dampingFraction: 0.82), value: shown?.id)
        .onChange(of: store.inAppAlert) { _, alert in
            guard let alert else { return }
            drag = 0
            shown = alert
        }
        .task(id: shown?.id) {
            guard shown != nil else { return }
            try? await Task.sleep(for: .seconds(6))
            dismiss()
        }
    }

    private func content(_ alert: InAppAlert) -> some View {
        Button {
            if let session = alert.sessionId { store.pendingSessionId = session }
            dismiss()
        } label: {
            HStack(spacing: 12) {
                ProviderGlyph(account: alert.account, provider: alert.provider, size: 38, pulsing: true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(alert.title)
                        .font(.subheadline.weight(.semibold))
                    Text(alert.question)
                        .font(.subheadline)
                        .lineLimit(2)
                    Text(alert.folder)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .contentShape(.rect(cornerRadius: 26))
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 26))
        .padding(.horizontal, 12)
        .accessibilityElement(children: .combine)
        .accessibilityHint(alert.sessionId == nil ? "" : "Opens the session")
        .accessibilityAddTraits(.isButton)
    }

    private func dismiss() {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            shown = nil
            drag = 0
        }
        store.inAppAlert = nil
    }
}
