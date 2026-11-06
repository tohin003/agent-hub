import SwiftUI

/// The agent was updated on the Mac while this session ran. It works on, but until it starts again macOS can't tell
/// which app it belongs to, so files dropped into its window on the Mac (a screenshot's floating thumbnail) can't be
/// opened. Restart starts it again with the same conversation, mode and model (Claude Code, between turns); other
/// agents are quit in their window, then started again from the ••• menu.
struct AgentUpdatedCard: View {
    var session: SessionInfo
    @Environment(HubStore.self) private var store
    @State private var confirming = false
    @State private var restarting = false

    private var name: String { session.provider.displayName }
    /// Claude Code is closed and started again from here; other agents are quit in their window first.
    private var restartsHere: Bool { session.provider == .claude }
    private var busy: Bool { session.state == .working || session.state == .starting }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(name) was updated on the Mac")
                        .font(.subheadline.weight(.semibold))
                    Text(explanation)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
            if restartsHere {
                Button {
                    if session.runningTasks > 0 { confirming = true } else { restart() }
                } label: {
                    Label(restarting ? "Restarting…" : "Restart \(name)", systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(busy || restarting)
            }
        }
        .padding(14)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
        .confirmationDialog("Restart \(name)?", isPresented: $confirming, titleVisibility: .visible) {
            Button("Restart and Stop Background Tasks", role: .destructive) { restart() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Its background tasks stop. The conversation carries on in the new version.")
        }
    }

    private var explanation: String {
        guard restartsHere else {
            return "Quit it in its window on the Mac, then choose Start the Agent Again in the ••• menu. Until then, "
                + "files dropped into its window can't be opened."
        }
        if busy {
            return "You can restart it when this turn ends. Until then, files dropped into its window on the Mac can't "
                + "be opened."
        }
        return "Restart it to use the new version: the conversation, mode and model carry on. Until then, files dropped "
            + "into its window on the Mac can't be opened."
    }

    private func restart() {
        restarting = true
        Task {
            await store.restart(session.id)
            restarting = false
        }
    }
}
