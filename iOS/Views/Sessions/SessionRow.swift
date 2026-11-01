import SwiftUI

struct SessionRow: View {
    var session: SessionInfo
    var account: Account?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ProviderGlyph(account: account, provider: session.provider, size: 42, pulsing: session.attention != nil && session.attention?.optional != true)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(session.title)
                        .font(.headline)
                        .lineLimit(2)
                    Spacer(minLength: 8)
                    if let time = session.lastActivity ?? Optional(session.createdAt) {
                        Text(time, format: .relative(presentation: .numeric, unitsStyle: .narrow))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                Text("\(account?.name ?? session.accountId) · \(session.cwd.lastPathComponent)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                detail
                HStack(spacing: 6) {
                    StateChip(state: session.state)
                    if session.runningTasks > 0 {
                        Label("\(session.runningTasks)", systemImage: "gearshape.2")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("\(session.runningTasks) background tasks")
                    }
                    if session.hasWindow {
                        Image(systemName: "macwindow")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Open on the Mac")
                    }
                }
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var detail: some View {
        if let attention = session.attention, attention.optional != true {
            Text(attention.question)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.orange)
                .lineLimit(2)
        } else if session.state == .working, let status = session.stateDetail, !status.isEmpty {
            Text(status)
                .font(.subheadline)
                .foregroundStyle(.tint)
                .lineLimit(1)
        } else if let last = session.lastMessage {
            Text(last)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
    }
}
