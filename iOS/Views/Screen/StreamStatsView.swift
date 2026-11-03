import SwiftUI

/// The live picture's numbers: frames per second, the round trip to the Mac, the picture's delay when it's known, the
/// data rate, the codec and how the picture comes (Tailscale's path over UDP, or TCP). A line under the navigation bar in portrait, which takes more lines rather than cut a
/// number short, and a stack in the landscape margin. Tap it to keep just the frame rate, and again for everything.
struct StreamStatsView: View {
    var stats: StreamStats
    /// The round trip to the Mac in milliseconds, when known.
    var roundTripMs: Double?
    /// The live numbers, read in this view's own body, so they redraw it alone and not the tab around it (whose
    /// rebuilds took taps from an open menu); nil: `stats` and `roundTripMs` as given.
    var live: (() -> (stats: StreamStats, roundTripMs: Double?))? = nil
    /// A line (portrait) or a stack (the landscape margin).
    var axis: Axis = .horizontal
    /// Shows how the picture comes; a short margin drops it first (VoiceOver still says it).
    var showingPath = true
    /// Which numbers show: a short landscape margin keeps the timing (frame rate, round trip, delay), or the frame
    /// rate alone, so the Spaces bar under them stays whole. VoiceOver and the large content viewer still give them all.
    var limit = Limit.all

    enum Limit {
        case all, timing, frameRate
    }
    @AppStorage("screen.statsCollapsed") private var collapsed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button {
            withAnimation(reduceMotion ? nil : .snappy) { collapsed.toggle() }
        } label: {
            Group {
                if axis == .horizontal { line } else { stack }
            }
            .font(.footnote.monospacedDigit())
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        // The margin is narrow: its numbers grow with the text as far as it holds them, and the large content viewer
        // shows them beyond that, as the system's bars do. The line under the navigation bar grows all the way.
        .dynamicTypeSize(axis == .vertical ? ...DynamicTypeSize.xxxLarge : ...DynamicTypeSize.accessibility5)
        .accessibilityShowsLargeContentViewer {
            Label(readings(path: true).map { [$0.value, $0.unit].filter { !$0.isEmpty }.joined(separator: " ") }
                    .joined(separator: ", "),
                  systemImage: "dot.radiowaves.left.and.right")
        }
        .accessibilityIdentifier("streamStats")
        .accessibilityLabel("Stream statistics")
        .accessibilityValue(readings(path: true).map(\.spoken).joined(separator: ", "))
        .accessibilityHint(collapsed ? "Shows the data rate, round trip and codec too." : "Shows only the frame rate.")
    }

    /// One line when it fits; else the timing over the data; a stack at the largest text sizes.
    private var line: some View {
        ViewThatFits(in: .horizontal) {
            row(readings, icon: true)
            VStack(spacing: 2) {
                row(readings.filter { $0.timing }, icon: true)
                row(readings.filter { !$0.timing }, icon: false)
            }
            VStack(spacing: 2) {
                ForEach(readings) { reading($0) }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 44)
    }

    private func row(_ readings: [Reading], icon: Bool) -> some View {
        HStack(spacing: 6) {
            if icon { self.icon }
            ForEach(Array(readings.enumerated()), id: \.element.id) { index, reading in
                if index > 0 {
                    Text(verbatim: "·")
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
                self.reading(reading)
            }
        }
    }

    /// Every number beside its unit when the margin is wide enough, else every number over its unit, each word on
    /// one line (a word too wide for the margin draws a little smaller rather than break or cut).
    private var stack: some View {
        ViewThatFits(in: .horizontal) {
            VStack(spacing: 6) {
                ForEach(readings) { reading($0) }
            }
            VStack(spacing: 6) {
                ForEach(readings) { reading in
                    VStack(spacing: 0) {
                        Text(reading.value)
                            .lineLimit(1)
                            .minimumScaleFactor(0.5)
                        if !reading.unit.isEmpty {
                            Text(reading.unit)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.5)
                        }
                    }
                }
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity, minHeight: 44)
    }

    private var icon: some View {
        Image(systemName: "dot.radiowaves.left.and.right")
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)
    }

    private func reading(_ reading: Reading) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(reading.value)
            if !reading.unit.isEmpty {
                Text(reading.unit)
                    .foregroundStyle(.secondary)
            }
        }
        .fixedSize()
    }

    /// One number and what it measures.
    private struct Reading: Identifiable {
        var id: String
        var value: String
        var unit: String
        /// For VoiceOver: the number with its unit in words.
        var spoken: String
        /// How quick the picture is (frame rate, round trip, delay), rather than what it carries.
        var timing: Bool
    }

    /// What's shown: every reading, less the path where there's no room for it.
    private var readings: [Reading] {
        let all = readings(path: showingPath)
        switch limit {
        case .all: return all
        case .timing: return all.filter(\.timing)
        case .frameRate: return all.filter { $0.id == "fps" }
        }
    }

    /// Timing first, then the data rate, the codec and the path.
    private func readings(path: Bool) -> [Reading] {
        let (stats, roundTripMs) = live?() ?? (stats: self.stats, roundTripMs: self.roundTripMs)
        let fps = Int(stats.framesPerSecond.rounded())
        // While the hub holds the frame rate down for the link or the motion, its target joins the number: "24/30 fps".
        var list = [stats.frameRateLimit.map {
            Reading(id: "fps", value: "\(fps)/\($0)", unit: "fps",
                    spoken: "\(fps) frames per second, held to \($0) for the connection", timing: true)
        } ?? Reading(id: "fps", value: "\(fps)", unit: "fps", spoken: "\(fps) frames per second", timing: true)]
        guard !collapsed else { return list }
        if let roundTripMs {
            let ms = Int(roundTripMs.rounded())
            list.append(Reading(id: "ping", value: "\(ms)", unit: "ms ping", spoken: "\(ms) milliseconds round trip",
                                timing: true))
        }
        if let delay = stats.delayMs {
            let ms = Int(delay.rounded())
            list.append(Reading(id: "delay", value: "\(ms)", unit: "ms delay", spoken: "\(ms) milliseconds behind the Mac",
                                timing: true))
        }
        let rate = stats.megabitsPerSecond.formatted(.number.precision(.fractionLength(stats.megabitsPerSecond < 10 ? 1 : 0)))
        list.append(Reading(id: "rate", value: rate, unit: "Mbit/s", spoken: "\(rate) megabits per second", timing: false))
        // "HEVC 4:4:4": the codec, then its chroma as the qualifier (its own line in the margin).
        let codec = stats.codec.split(separator: " ", maxSplits: 1).map(String.init)
        if let name = codec.first {
            list.append(Reading(id: "codec", value: name, unit: codec.count > 1 ? codec[1] : "", spoken: stats.codec,
                                timing: false))
        }
        if path, !stats.path.isEmpty {
            list.append(Reading(id: "path", value: stats.path, unit: "", spoken: Self.spoken(path: stats.path),
                                timing: false))
        }
        return list
    }

    /// The path in words, for VoiceOver.
    private static func spoken(path: String) -> String {
        switch path {
        case "Direct": "over UDP, straight to the Mac"
        case "Relay": "over UDP, through a Tailscale peer relay"
        case "DERP": "over UDP, through a Tailscale relay server"
        case "UDP": "over UDP"
        default: "over TCP"
        }
    }
}
