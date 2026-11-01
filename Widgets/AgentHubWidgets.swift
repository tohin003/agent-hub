import ActivityKit
import SwiftUI
import WidgetKit

/// Agent Hub's Lock Screen and Dynamic Island: which session needs you, and what the agents are doing.
@main
struct AgentHubWidgets: WidgetBundle {
    var body: some Widget {
        SessionsLiveActivity()
    }
}

/// Starlight, the app's one colour, and the black it sits on.
private enum Look {
    static let starlight = Color(red: 0.914, green: 0.878, blue: 0.812)
    static let highlight = Color(red: 0.980, green: 0.965, blue: 0.937)
    static let shadow = Color(red: 0.784, green: 0.733, blue: 0.651)
    static let graphite = Color(red: 0.165, green: 0.149, blue: 0.133)
    static let attention = Color(red: 1.0, green: 0.62, blue: 0.26)
}

struct SessionsLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: SessionsActivity.self) { context in
            LockScreenView(state: context.state, macName: context.attributes.macName,
                           logos: ActivityLogos.logos(context.attributes))
                .activityBackgroundTint(Color.black.opacity(0.78))
                .activitySystemActionForegroundColor(Look.starlight)
                .widgetURL(link(context.state))
        } dynamicIsland: { context in
            let state = context.state
            let logos = ActivityLogos.logos(context.attributes)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Orb(phase: state.phase, size: 52, logos: logos)
                        .padding(.leading, 2)
                        .padding(.top, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Counts(state: state)
                        .padding(.trailing, 6)
                        .padding(.top, 6)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(spacing: 2) {
                        Text(state.title)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        Text(state.account)
                            .font(.caption)
                            .foregroundStyle(Look.starlight.opacity(0.7))
                            .lineLimit(1)
                    }
                    .padding(.top, 6)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: symbol(state.phase))
                            .foregroundStyle(state.phase == .waiting ? Look.attention : Look.starlight)
                        Text(state.detail)
                            .font(.callout)
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if state.phase == .working, let since = state.since {
                            Text(timerInterval: since...Date.distantFuture, countsDown: false)
                                .font(.callout.monospacedDigit())
                                .foregroundStyle(Look.starlight.opacity(0.7))
                                .frame(width: 52, alignment: .trailing)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 4)
                }
            } compactLeading: {
                Orb(phase: state.phase, size: 24, logos: logos)
            } compactTrailing: {
                CompactTrailing(state: state)
            } minimal: {
                Orb(phase: state.phase, size: 22, logos: logos)
            }
            .widgetURL(link(state))
            .keylineTint(state.phase == .waiting ? Look.attention : Look.starlight)
        }
    }

    private func link(_ state: SessionsActivity.ContentState) -> URL? {
        guard let id = state.sessionId else { return URL(string: "agenthub://sessions") }
        return URL(string: "agenthub://session/\(id)")
    }

    private func symbol(_ phase: SessionsActivity.ContentState.Phase) -> String {
        switch phase {
        case .waiting: "hand.raised.fill"
        case .working: "ellipsis"
        case .done: "checkmark.circle.fill"
        }
    }
}

/// The mascot, as in the app: the Starlight blob with the agents' logos circling it (sent along tiny, see
/// `SessionsActivity.logos`), asking when a session needs you, busy while agents work, happy when all is done.
struct Orb: View {
    var phase: SessionsActivity.ContentState.Phase
    var size: Double
    var logos: [TerminalLogo] = []

    var body: some View {
        BlobView(mood: mood, animated: false, logos: logos)
            .environment(\.colorScheme, .dark)
            .frame(width: size, height: size)
            .accessibilityLabel(phase == .waiting ? "Needs you" : (phase == .working ? "Working" : "Done"))
    }

    private var mood: BlobMood {
        switch phase {
        case .waiting: .attention
        case .working: .working
        case .done: .happy
        }
    }
}

/// The logos as they travel in the activity (tiny RGB pictures), back into terminal art: two pixel rows per text row,
/// drawn with "▀" in the top pixel's colour on the bottom pixel's.
enum ActivityLogos {
    static func logos(_ attributes: SessionsActivity) -> [TerminalLogo] {
        let n = attributes.logoPixels
        return attributes.logos.compactMap { data in
            guard n > 0, data.count == n * n * 3 else { return nil }
            let bytes = [UInt8](data)
            func pixel(_ x: Int, _ y: Int) -> (UInt8, UInt8, UInt8) {
                let i = (y * n + x) * 3
                return (bytes[i], bytes[i + 1], bytes[i + 2])
            }
            var lines: [String] = []
            for y in stride(from: 0, to: n - 1, by: 2) {
                var line = ""
                for x in 0..<n {
                    let top = pixel(x, y), bottom = pixel(x, y + 1)
                    line += "\u{1B}[38;2;\(top.0);\(top.1);\(top.2)m\u{1B}[48;2;\(bottom.0);\(bottom.1);\(bottom.2)m▀"
                }
                lines.append(line + "\u{1B}[0m")
            }
            return TerminalLogo(mark: lines, full: lines, source: "art", capturedAt: .distantPast)
        }
    }
}

struct Counts: View {
    var state: SessionsActivity.ContentState

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            if state.waiting > 0 {
                Label("\(state.waiting)", systemImage: "hand.raised.fill")
                    .foregroundStyle(Look.attention)
            }
            if state.working > 0 {
                Label("\(state.working)", systemImage: "gearshape.2.fill")
                    .foregroundStyle(Look.starlight)
            }
        }
        .font(.caption.weight(.semibold).monospacedDigit())
        .labelStyle(.titleAndIcon)
    }
}

struct CompactTrailing: View {
    var state: SessionsActivity.ContentState

    var body: some View {
        switch state.phase {
        case .waiting:
            Image(systemName: "hand.raised.fill")
                .foregroundStyle(Look.attention)
                .accessibilityLabel("\(state.waiting) need you")
        case .working:
            if let since = state.since {
                Text(timerInterval: since...Date.distantFuture, countsDown: false)
                    .font(.caption2.monospacedDigit().weight(.medium))
                    .foregroundStyle(Look.starlight)
                    .frame(width: 40)
            } else {
                Image(systemName: "ellipsis").foregroundStyle(Look.starlight)
            }
        case .done:
            Image(systemName: "checkmark").foregroundStyle(Look.starlight)
        }
    }
}

struct LockScreenView: View {
    var state: SessionsActivity.ContentState
    var macName: String
    var logos: [TerminalLogo] = []

    var body: some View {
        HStack(spacing: 14) {
            Orb(phase: state.phase, size: 60, logos: logos)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(state.title).font(.headline).lineLimit(1)
                    Spacer(minLength: 4)
                    Counts(state: state)
                }
                Text(state.detail)
                    .font(.subheadline)
                    .foregroundStyle(state.phase == .waiting ? Look.highlight : Look.starlight.opacity(0.8))
                    .lineLimit(2)
                HStack(spacing: 6) {
                    Text(state.account)
                    Text("·")
                    Text(macName)
                    if state.phase == .working, let since = state.since {
                        Text("·")
                        Text(timerInterval: since...Date.distantFuture, countsDown: false).monospacedDigit()
                    }
                }
                .font(.caption)
                .foregroundStyle(Look.starlight.opacity(0.6))
            }
        }
        .foregroundStyle(Look.highlight)
        .padding(16)
    }
}
