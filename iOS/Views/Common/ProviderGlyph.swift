import SwiftUI

/// The agent's own CLI logo, as the hub read it from the CLI's screen, plus the account's short tag ("W", "P"). An
/// orange ring pulses while the session waits for you.
struct ProviderGlyph: View {
    var account: Account?
    var provider: ProviderKind
    var size: Double = 40
    var pulsing = false

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            CLILogoTile(logo: account?.logo, fallback: monogram, size: size)
                .overlay {
                    if pulsing {
                        RoundedRectangle(cornerRadius: size * 0.3)
                            .stroke(Color.orange, lineWidth: 2.5)
                            .frame(width: size + 6, height: size + 6)
                            .phaseAnimator([0.35, 1]) { content, phase in
                                content.opacity(phase)
                            } animation: { _ in .easeInOut(duration: 0.9) }
                    }
                }
            if let badge = account?.badge {
                Text(badge)
                    .font(.system(size: size * 0.27, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.onAccent)
                    .frame(width: size * 0.44, height: size * 0.44)
                    .background(Circle().fill(Color.accentColor))
                    .overlay(Circle().stroke(Color(.systemBackground), lineWidth: max(1.5, size * 0.04)))
                    .offset(x: size * 0.12, y: size * 0.12)
            }
        }
        .accessibilityHidden(true)
    }

    /// Until the hub has read the CLI's logo: the first letter of the account's name (a prompt for a plain shell).
    private var monogram: String {
        if provider == .shell { return "%_" }
        return (account?.name ?? provider.displayName).first.map { String($0).uppercased() } ?? "?"
    }
}

/// A small capsule with a session's state in words and a symbol.
struct StateChip: View {
    var state: SessionState

    var body: some View {
        Label(state.title, systemImage: state.symbol)
            .font(.footnote.weight(.medium))
            .foregroundStyle(state.tint)
            .labelStyle(.titleAndIcon)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(state.tint.opacity(0.12), in: .capsule)
            .symbolEffect(.pulse, isActive: state == .working)
            .symbolEffect(.bounce, value: state == .waiting)
            .contentTransition(.symbolEffect(.replace))
            .animation(.spring(response: 0.35, dampingFraction: 0.8), value: state)
    }
}
