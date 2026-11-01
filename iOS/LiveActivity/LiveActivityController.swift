import ActivityKit
import AVFoundation
import Foundation
import UIKit

/// Keeps the Live Activity (Lock Screen and Dynamic Island) in step with your sessions: the one that needs you first,
/// else the one at work, with counts; when a session starts needing you, the island expands with your alert style.
/// A free Apple ID can't use push, so it's updated while the app runs (and, with Stay Connected, in the background).
@MainActor
final class LiveActivityController {
    static let shared = LiveActivityController()
    static let enabledKey = "live.enabled"

    private var activity: Activity<SessionsActivity>?
    private var last: SessionsActivity.ContentState?
    /// When each session started working, for the island's timer.
    private var workingSince: [String: Date] = [:]
    private var ending: Task<Void, Never>?

    var enabled: Bool { UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true }

    func update(sessions: [SessionInfo], accounts: [Account], macName: String) {
        for session in sessions where session.state == .working && workingSince[session.id] == nil {
            workingSince[session.id] = .now
        }
        for session in sessions where session.state != .working { workingSince[session.id] = nil }

        guard enabled, ActivityAuthorizationInfo().areActivitiesEnabled else {
            end(immediately: true)
            return
        }
        if activity == nil { activity = Activity<SessionsActivity>.activities.first }
        guard let state = state(sessions: sessions, accounts: accounts) else {
            // All caught up: say so for a moment, then leave.
            if let last, last.phase != .done {
                var done = last
                done.phase = .done
                done.detail = "All caught up."
                done.waiting = 0
                done.working = 0
                done.since = nil
                self.last = done
                end(with: done)
            }
            return
        }
        guard state != last else { return }
        let newlyWaiting = state.phase == .waiting && (last?.phase != .waiting || last?.sessionId != state.sessionId)
        last = state
        ending?.cancel()
        let content = ActivityContent(state: state, staleDate: .now.addingTimeInterval(15 * 60),
                                      relevanceScore: state.phase == .waiting ? 100 : 50)
        if let activity {
            let alert = newlyWaiting ? alertConfiguration(state) : nil
            // ActivityKit's Activity is safe to use from any thread; it just isn't marked Sendable.
            nonisolated(unsafe) let target = activity
            Task { await target.update(content, alertConfiguration: alert) }
        } else if UIApplication.shared.applicationState == .active {
            // The agents' logos ride along, tiny, for the mascot's orbit on the Lock Screen and in the island.
            let attributes = SessionsActivity(macName: macName, logos: LogoBitmaps.make(Account.orbitLogos(accounts)), logoPixels: 12)
            activity = try? Activity.request(attributes: attributes, content: content, pushType: nil)
        }
    }

    /// The island expands with the question; your alert style decides the sound (a chime, a silent tap, or none).
    private func alertConfiguration(_ state: SessionsActivity.ContentState) -> AlertConfiguration? {
        let sound: AlertConfiguration.AlertSound
        switch AlertStyle.current {
        case .chime: sound = .named("AgentHubChime.caf")
        case .vibrate: sound = .named("AgentHubSilent.caf")
        case .silent: return nil
        }
        return AlertConfiguration(title: "\(state.account) needs you", body: "\(state.detail)", sound: sound)
    }

    /// Needs you first (the newest question), else the session at work the longest.
    private func state(sessions: [SessionInfo], accounts: [Account]) -> SessionsActivity.ContentState? {
        let live = sessions.filter { $0.state != .ended && $0.state != .exited }
        let waiting = live.filter { $0.attention != nil && $0.attention?.optional != true }
        let working = live.filter { $0.state == .working || $0.state == .starting }
        func name(_ session: SessionInfo) -> String {
            accounts.first { $0.id == session.accountId }?.name ?? session.accountId
        }
        if let session = waiting.max(by: { ($0.lastActivity ?? .distantPast) < ($1.lastActivity ?? .distantPast) }) {
            return .init(sessionId: session.id, title: session.title, account: name(session), phase: .waiting,
                         detail: session.attention?.question ?? "Waiting for you", waiting: waiting.count,
                         working: working.count, since: nil)
        }
        if let session = working.min(by: { (workingSince[$0.id] ?? .now) < (workingSince[$1.id] ?? .now) }) {
            return .init(sessionId: session.id, title: session.title, account: name(session), phase: .working,
                         detail: session.stateDetail ?? "Working", waiting: 0, working: working.count,
                         since: workingSince[session.id])
        }
        return nil
    }

    private func end(with final: SessionsActivity.ContentState) {
        guard let activity else { return }
        ending?.cancel()
        nonisolated(unsafe) let target = activity
        let id = activity.id
        ending = Task {
            await target.update(ActivityContent(state: final, staleDate: nil, relevanceScore: 10))
            try? await Task.sleep(for: .seconds(90))
            guard !Task.isCancelled else { return }
            await target.end(ActivityContent(state: final, staleDate: nil), dismissalPolicy: .immediate)
            if self.activity?.id == id { self.activity = nil }
        }
    }

    func end(immediately: Bool) {
        guard let activity else { return }
        self.activity = nil
        last = nil
        nonisolated(unsafe) let target = activity
        Task { await target.end(nil, dismissalPolicy: .immediate) }
    }
}

/// Stay Connected (off unless you turn it on): keeps the app running after you leave it, with a silent audio
/// session, so the Dynamic Island, notifications and answers keep working while the phone is in your pocket. It uses
/// more battery; the Mac tab says so where you turn it on.
@MainActor
final class BackgroundKeeper {
    static let shared = BackgroundKeeper()
    static let key = "background.stayConnected"
    private var player: AVAudioPlayer?
    private var observer: NSObjectProtocol?

    var enabled: Bool { UserDefaults.standard.bool(forKey: Self.key) }

    func enterBackground() {
        guard enabled else { return }
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, options: [.mixWithOthers])
        try? session.setActive(true)
        if player == nil, let url = Bundle.main.url(forResource: "AgentHubSilent", withExtension: "caf") {
            player = try? AVAudioPlayer(contentsOf: url)
            player?.numberOfLoops = -1
        }
        player?.play()
        // A call or another app's audio pauses it; carry on afterwards.
        if observer == nil {
            observer = NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil,
                                                              queue: .main) { note in
                guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                      AVAudioSession.InterruptionType(rawValue: raw) == .ended else { return }
                Task { @MainActor in BackgroundKeeper.shared.resume() }
            }
        }
    }

    private func resume() {
        guard enabled, UIApplication.shared.applicationState != .active else { return }
        try? AVAudioSession.sharedInstance().setActive(true)
        player?.play()
    }

    func enterForeground() {
        guard player?.isPlaying == true else { return }
        player?.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
