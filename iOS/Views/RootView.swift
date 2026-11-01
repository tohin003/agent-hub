import SwiftUI
import UserNotifications

/// The three places in Agent Hub: your sessions, your Mac's screen, and the Mac itself.
struct RootView: View {
    enum Section: Hashable {
        case sessions, screen, mac
    }

    @Environment(HubStore.self) private var store
    @Environment(\.scenePhase) private var scenePhase
    @State private var section: Section = .sessions

    var body: some View {
        TabView(selection: $section) {
            Tab("Sessions", systemImage: "bubble.left.and.text.bubble.right", value: Section.sessions) {
                SessionsView()
            }
            .badge(store.waitingCount)
            Tab("Screen", systemImage: "display", value: Section.screen) {
                ScreenTab(isActive: section == .screen)
            }
            Tab("Mac", systemImage: "laptopcomputer", value: Section.mac) {
                MacTab()
            }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        .sensoryFeedback(.selection, trigger: section)
        .overlay(alignment: .top) {
            VStack(spacing: 8) {
                InAppAlertBanner()
                ToastView()
            }
        }
        .task {
            applyLaunchArguments()
            // `-demo <file>`: a made-up Mac for screenshots, nothing connects.
            if let path = UserDefaults.standard.string(forKey: "demo"), let snapshot = DemoSnapshot.load(path) {
                store.loadDemo(snapshot)
                LiveActivityController.shared.update(sessions: snapshot.sessions, accounts: snapshot.accounts, macName: store.macName)
                if let session = UserDefaults.standard.string(forKey: "openSession") { store.pendingSessionId = session }
                return
            }
            await store.connect()
            if let session = UserDefaults.standard.string(forKey: "openSession") { store.pendingSessionId = session }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                BackgroundKeeper.shared.enterForeground()
                if !store.isConnected { Task { await store.connect() } }
            case .background:
                AttentionNotifier.shared.armBackgroundWatch(store: store)
                BackgroundKeeper.shared.enterBackground()
            default:
                break
            }
        }
        .onOpenURL { url in
            Task { await open(url) }
        }
        .onChange(of: store.pendingSessionId) { _, id in
            // Opening a session (a resumed conversation, a notification) always lands on the Sessions tab.
            if id != nil { section = .sessions }
        }
        .onChange(of: store.sessions) { old, new in
            AttentionNotifier.shared.notifyNewAttention(old: old, new: new, accounts: store.accounts, store: store)
            LiveActivityController.shared.update(sessions: new, accounts: store.accounts, macName: store.macName)
        }
    }

    /// `-startTab screen|mac` and `-openSession <id>` open a screen directly (used for checks and screenshots).
    private func applyLaunchArguments() {
        switch UserDefaults.standard.string(forKey: "startTab") {
        case "screen": section = .screen
        case "mac": section = .mac
        default: break
        }
    }

    private func open(_ url: URL) async {
        if url.host == "pair" {
            let ok = await store.applyPairing(url)
            store.toast = ToastEvent(message: ok ? "Paired with \(store.settings.macName)." : "That pairing link isn't complete.",
                                     level: ok ? "info" : "error")
            section = .mac
        } else if url.host == "session" {
            store.pendingSessionId = url.lastPathComponent
            section = .sessions
        } else if url.host == "sessions" {
            section = .sessions
        }
    }
}

/// A short message at the top of the screen for failures and confirmations.
struct ToastView: View {
    @Environment(HubStore.self) private var store

    var body: some View {
        if let toast = store.toast {
            Label(toast.message, systemImage: toast.level == "error" ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .font(.callout)
                .foregroundStyle(toast.level == "error" ? Color.orange : Color.green)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .glassEffect(.regular, in: .capsule)
                .padding(.horizontal)
                .padding(.top, 4)
                .transition(.move(edge: .top).combined(with: .opacity))
                .task(id: toast.message) {
                    try? await Task.sleep(for: .seconds(toast.level == "error" ? 5 : 3))
                    withAnimation { store.toast = nil }
                }
                .onTapGesture { withAnimation { store.toast = nil } }
                .accessibilityAddTraits(.isButton)
        }
    }
}
