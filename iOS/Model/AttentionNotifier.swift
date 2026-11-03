import Foundation
import UIKit
import UserNotifications

/// Tells you when a session starts waiting for you:
/// - in the app, a glass banner with your chosen chime or tap (unless you're looking at that session already);
/// - outside it (in the time iOS keeps the app running after you leave), a notification with the agent's own answers
///   as buttons, Face ID first, so you can approve from the lock screen. Free signing can't use push; see the Mac tab
///   for ntfy when the app is closed.
@MainActor
final class AttentionNotifier {
    static let shared = AttentionNotifier()
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    /// The answer categories registered now (one per question, the newest few kept).
    private var categories: [UNNotificationCategory] = []
    /// The session on screen: no banner for the one you're already looking at.
    var visibleSessionId: String?

    func notifyNewAttention(old: [SessionInfo], new: [SessionInfo], accounts: [Account], store: HubStore) {
        let before = Dictionary(old.map { ($0.id, $0.attention?.signature) }, uniquingKeysWith: { a, _ in a })
        for session in new where session.attention != nil && session.attention?.optional != true && session.state != .ended {
            guard let prompt = session.attention, before[session.id] != prompt.signature else { continue }
            let account = accounts.first { $0.id == session.accountId }
            let style = AlertStyle.current
            if UIApplication.shared.applicationState == .active {
                guard session.id != visibleSessionId else { continue }
                store.inAppAlert = InAppAlert(sessionId: session.id, title: "\(account?.name ?? "An agent") needs you",
                                              question: prompt.question, folder: session.cwd.lastPathComponent,
                                              provider: session.provider, account: account)
                style.playInApp()
                continue
            }
            let content = UNMutableNotificationContent()
            content.title = account?.name ?? "An agent"
            content.subtitle = "\(session.title) · \(session.cwd.lastPathComponent)"
            content.body = prompt.question
            content.sound = style.notificationSound
            content.interruptionLevel = .timeSensitive
            content.relevanceScore = 1
            content.userInfo = ["session": session.id, "signature": prompt.signature]
            content.threadIdentifier = session.id
            content.targetContentIdentifier = session.id
            content.categoryIdentifier = register(prompt)
            let request = UNNotificationRequest(identifier: "\(session.id)-\(prompt.signature)", content: content, trigger: nil)
            UNUserNotificationCenter.current().add(request)
        }
        // Answered on the Mac or elsewhere: its notification goes.
        let waiting = Set(new.compactMap { session in session.attention.map { "\(session.id)-\($0.signature)" } })
        let gone = old.compactMap { session in session.attention.map { "\(session.id)-\($0.signature)" } }.filter { !waiting.contains($0) }
        if !gone.isEmpty { UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: gone) }
    }

    /// The question's own answers as notification buttons (up to three, the declining one last and red), behind
    /// Face ID: approving a command on the Mac shouldn't be possible from a locked phone.
    private func register(_ prompt: AttentionPrompt) -> String {
        let identifier = "attention-\(prompt.signature)"
        guard !categories.contains(where: { $0.identifier == identifier }) else { return identifier }
        var actions: [UNNotificationAction] = []
        if prompt.multiSelect != true, prompt.horizontal != true {
            let choices = prompt.options.filter { !$0.isToggle }
            let positive = choices.filter { !$0.isNegative && $0.takesText != true }.prefix(2)
            let negative = choices.first { $0.isNegative && $0.takesText != true }
            for option in positive {
                actions.append(UNNotificationAction(identifier: "answer-\(option.index)", title: option.label,
                                                    options: [.authenticationRequired]))
            }
            if let typed = choices.first(where: { $0.takesText == true }) {
                actions.append(UNTextInputNotificationAction(identifier: "type-\(typed.index)", title: typed.label,
                                                             options: [.authenticationRequired],
                                                             textInputButtonTitle: "Send", textInputPlaceholder: typed.label))
            }
            if let negative {
                actions.append(UNNotificationAction(identifier: "answer-\(negative.index)", title: negative.label,
                                                    options: [.authenticationRequired, .destructive]))
            }
        }
        let category = UNNotificationCategory(identifier: identifier, actions: Array(actions.prefix(4)), intentIdentifiers: [],
                                              options: [.customDismissAction])
        categories = Array((categories + [category]).suffix(12))
        UNUserNotificationCenter.current().setNotificationCategories(Set(categories))
        return identifier
    }

    /// Asks iOS for a little time after the app leaves the screen, so a prompt arriving just then still notifies.
    func armBackgroundWatch(store: HubStore) {
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "agenthub.watch") { [weak self] in
            self?.endBackgroundWatch()
        }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(25))
            self?.endBackgroundWatch()
        }
    }

    private func endBackgroundWatch() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    /// A sample alert, in the style chosen (from the Mac tab).
    func test(style: AlertStyle, store: HubStore) {
        store.inAppAlert = InAppAlert(sessionId: nil, title: "Claude needs you", question: "Do you want to proceed?",
                                      folder: "This is how alerts look", provider: .claude, account: nil)
        style.playInApp()
    }
}

/// The banner shown in the app when another session needs you.
struct InAppAlert: Identifiable, Equatable {
    let id = UUID()
    var sessionId: String?
    var title: String
    var question: String
    var folder: String
    var provider: ProviderKind
    var account: Account?

    static func == (a: InAppAlert, b: InAppAlert) -> Bool { a.id == b.id }
}

/// Opens the session a notification is about, and answers from its buttons. Also tells iOS which way the app may turn.
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    @MainActor var store: HubStore?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    /// Upright, except while the Screen tab is laid on its side (`OrientationLock`).
    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        OrientationLock.shared.supported
    }

    /// In the app, the in-app banner speaks for it.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification)
        async -> UNNotificationPresentationOptions {
        []
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        guard let session = info["session"] as? String else { return }
        let signature = info["signature"] as? String
        let action = response.actionIdentifier
        let typed = (response as? UNTextInputNotificationResponse)?.userText
        await MainActor.run {
            guard let store = self.store else { return }
            if action.hasPrefix("answer-"), let signature, let index = Int(action.dropFirst(7)) {
                Task { await store.answerFromNotification(session: session, signature: signature, option: index, text: nil) }
            } else if action.hasPrefix("type-"), let signature, let index = Int(action.dropFirst(5)), let typed {
                Task { await store.answerFromNotification(session: session, signature: signature, option: index, text: typed) }
            } else if action == UNNotificationDefaultActionIdentifier {
                store.pendingSessionId = session
            }
        }
    }
}
