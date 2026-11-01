import AudioToolbox
import Foundation
import UIKit
import UserNotifications

/// How Agent Hub gets your attention when a session needs you: its chime, a vibration only, or silently (a banner).
enum AlertStyle: String, CaseIterable, Identifiable {
    case chime, vibrate, silent

    var id: String { rawValue }

    var title: String {
        switch self {
        case .chime: "Chime"
        case .vibrate: "Vibrate Only"
        case .silent: "Silent"
        }
    }

    var detail: String {
        switch self {
        case .chime: "Agent Hub's soft two-note chime, and a tap."
        case .vibrate: "A tap, no sound."
        case .silent: "Just the banner."
        }
    }

    var symbol: String {
        switch self {
        case .chime: "bell.and.waves.left.and.right"
        case .vibrate: "iphone.radiowaves.left.and.right"
        case .silent: "bell.slash"
        }
    }

    static let key = "alerts.style"

    static var current: AlertStyle {
        AlertStyle(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .chime
    }

    /// The sound a notification carries. iOS taps only when a notification plays a sound, so "vibrate only" plays a
    /// silent one.
    var notificationSound: UNNotificationSound? {
        switch self {
        case .chime: UNNotificationSound(named: UNNotificationSoundName("AgentHubChime.caf"))
        case .vibrate: UNNotificationSound(named: UNNotificationSoundName("AgentHubSilent.caf"))
        case .silent: nil
        }
    }

    /// While the app is open: the chime and a tap, a tap, or nothing.
    @MainActor
    func playInApp() {
        switch self {
        case .chime:
            Self.chimeSound.play()
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
        case .vibrate:
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
        case .silent:
            break
        }
    }

    private static let chimeSound = SoundEffect(named: "AgentHubChime", extension: "caf")
}

/// A short bundled sound, played the system-sound way (it respects the ring/silent switch).
final class SoundEffect {
    private var id: SystemSoundID = 0

    init(named name: String, extension ext: String) {
        if let url = Bundle.main.url(forResource: name, withExtension: ext) {
            AudioServicesCreateSystemSoundID(url as CFURL, &id)
        }
    }

    func play() {
        guard id != 0 else { return }
        AudioServicesPlaySystemSound(id)
    }
}
