import SwiftUI

/// The Mac's volume and brightness, whether its sound plays on this iPhone, and whether the picture waits for it.
struct MacControlsSheet: View {
    var displayId: UInt32?
    @Binding var playSound: Bool
    var sound: MacAudioClient
    var sharing: Bool
    /// Lip-sync (`MediaSync`): off, the picture is never held back (the lowest delay); on, it waits for the sound.
    @AppStorage("screen.lipSync") private var lipSync = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Play Mac Sound Here", systemImage: "speaker.wave.2", isOn: $playSound)
                        .disabled(!sharing && !playSound)
                    Toggle(isOn: $lipSync) {
                        Label {
                            Text("Lip-Sync")
                            Text("Holds the picture back to match the sound, which AirPods delay. Off: the lowest delay.")
                        } icon: {
                            Image(systemName: "mouth")
                        }
                    }
                    if playSound, sound.playing {
                        SoundTimingRow()
                    }
                } footer: {
                    Text(soundNote)
                }
                MacLevelsSection(title: "Mac", displayId: displayId)
            }
            .navigationTitle("Sound & Brightness")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", systemImage: "checkmark") { dismiss() }
                }
            }
        }
    }

    private var soundNote: String {
        if !sharing { return "Turn on the live screen to hear your Mac here." }
        if playSound, let error = sound.error { return error }
        if playSound, sound.playing, lipSync {
            return "Your Mac's sound is playing here, in step with the picture, even while the Mac is muted."
        }
        if playSound, sound.playing { return "Your Mac's sound is playing here, even while the Mac is muted." }
        return "Hear your Mac on this iPhone, even while the Mac is muted. It keeps playing when the iPhone locks."
    }
}

/// While the Mac's sound plays: how far behind the Mac the sound and the picture are, from capture to the ear and to
/// the glass, so what Lip-Sync (and AirPods) do can be seen. Read once a second.
private struct SoundTimingRow: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let sound = MediaSync.shared.soundDelay()
            let picture = MediaSync.shared.shownPictureDelay()
            LabeledContent("Behind the Mac") {
                Text(Self.describe(sound: sound, picture: picture, unit: "ms"))
                    .monospacedDigit()
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Behind the Mac")
            .accessibilityValue(Self.describe(sound: sound, picture: picture, unit: "milliseconds"))
        }
    }

    private static func describe(sound: Double?, picture: Double?, unit: String) -> String {
        var parts: [String] = []
        if let sound { parts.append("sound \(Int(sound.rounded())) \(unit)") }
        if let picture { parts.append("picture \(Int(picture.rounded())) \(unit)") }
        guard !parts.isEmpty else { return "Measuring…" }
        let text = parts.joined(separator: ", ")
        return text.prefix(1).uppercased() + text.dropFirst()
    }
}

/// The Mac's volume, mute and brightness, read from the Mac each time the section appears. Used by the Screen tab's
/// sheet and by the Mac tab.
struct MacLevelsSection: View {
    var title: String
    /// Whose brightness: the display shown in the Screen tab, or the main display.
    var displayId: UInt32?
    @Environment(HubStore.self) private var store
    @State private var levels: MacLevels?
    @State private var volume = 0.0
    @State private var brightness = 0.0
    @State private var problem: String?
    @State private var sender = LevelSender()

    var body: some View {
        Section {
            if let levels {
                volumeRows(levels)
                brightnessRow(levels)
            } else if let problem {
                Text(problem)
                    .foregroundStyle(.secondary)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity)
            }
        } header: {
            Text(title)
        } footer: {
            if levels != nil, let problem { Text(problem) }
        }
        .task { await load() }
    }

    @ViewBuilder private func volumeRows(_ levels: MacLevels) -> some View {
        if levels.volume != nil {
            Slider(value: Binding(get: { volume }, set: { setVolume($0) }), in: 0...1) {
                Text("Volume")
            } minimumValueLabel: {
                Image(systemName: "speaker.fill")
            } maximumValueLabel: {
                Image(systemName: "speaker.wave.3.fill")
            }
        } else {
            Label("This Mac's sound output has no volume control.", systemImage: "speaker.slash")
                .foregroundStyle(.secondary)
        }
        if let muted = levels.muted {
            Toggle("Mute", systemImage: "speaker.slash", isOn: Binding(get: { muted }, set: { mute in
                self.levels?.muted = mute
                change(MacLevelsParams(displayId: displayId, muted: mute))
            }))
        }
    }

    @ViewBuilder private func brightnessRow(_ levels: MacLevels) -> some View {
        if levels.brightness != nil {
            Slider(value: Binding(get: { brightness }, set: { setBrightness($0) }), in: 0...1) {
                Text("Brightness")
            } minimumValueLabel: {
                Image(systemName: "sun.min")
            } maximumValueLabel: {
                Image(systemName: "sun.max.fill")
            }
        } else {
            Label("This display's brightness can't be changed from here.", systemImage: "sun.max")
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Actions

    private func load() async {
        do {
            let current: MacLevels = try await store.client.request(Method.macLevels, MacLevelsParams(displayId: displayId))
            levels = current
            volume = current.volume ?? 0
            brightness = current.brightness ?? 0
            problem = nil
        } catch {
            problem = HubClient.describe(error)
        }
    }

    /// Turning the volume up also unmutes, as the Mac's own volume keys do.
    private func setVolume(_ value: Double) {
        volume = value
        let unmute = levels?.muted == true && value > 0
        if unmute { levels?.muted = false }
        change(MacLevelsParams(displayId: displayId, volume: value, muted: unmute ? false : nil))
    }

    private func setBrightness(_ value: Double) {
        brightness = value
        change(MacLevelsParams(displayId: displayId, brightness: value))
    }

    /// The slider stays where the finger left it; the Mac's answer updates what's available and muted.
    private func change(_ params: MacLevelsParams) {
        sender.send(params, store: store) { result in
            switch result {
            case .success(let current):
                levels = current
                problem = nil
            case .failure(let error):
                problem = HubClient.describe(error)
            }
        }
    }
}

/// One request at a time: while one is on its way, the newest change waits, so a dragged slider sends a steady
/// trickle instead of a flood.
@MainActor
final class LevelSender {
    private var waiting: MacLevelsParams?
    private var busy = false

    func send(_ change: MacLevelsParams, store: HubStore, done: @escaping (Result<MacLevels, Error>) -> Void) {
        waiting = waiting.map { Self.merge($0, change) } ?? change
        guard !busy else { return }
        busy = true
        Task {
            while let next = waiting {
                waiting = nil
                do {
                    let levels: MacLevels = try await store.client.request(Method.macLevels, next)
                    done(.success(levels))
                } catch {
                    done(.failure(error))
                }
            }
            busy = false
        }
    }

    private static func merge(_ older: MacLevelsParams, _ newer: MacLevelsParams) -> MacLevelsParams {
        MacLevelsParams(displayId: newer.displayId ?? older.displayId, volume: newer.volume ?? older.volume,
                        muted: newer.muted ?? older.muted, brightness: newer.brightness ?? older.brightness)
    }
}
