import SwiftUI

/// Your Mac: the connection, what macOS still needs to allow, your agent accounts and their past conversations,
/// this app's signing, and alerts while the app is closed.
struct MacTab: View {
    @Environment(HubStore.self) private var store
    @AppStorage(AlertStyle.key) private var alertStyleRaw = AlertStyle.chime.rawValue
    @AppStorage(LiveActivityController.enabledKey) private var liveActivity = true
    @AppStorage(BackgroundKeeper.key) private var stayConnected = false
    @State private var showingPairing = false
    @State private var ntfy = ""
    @State private var renewing = false

    var body: some View {
        NavigationStack {
            List {
                header
                connection
                if store.isConnected {
                    MacLevelsSection(title: "Sound & Brightness", displayId: nil)
                }
                permissions
                accounts
                signing
                alertStyle
                alerts
                about
            }
            .navigationTitle("Mac")
            .refreshable { await store.refreshSessions() }
            .sheet(isPresented: $showingPairing) { PairingSheet() }
            .task { await store.refreshHub() }
        }
    }

    private var header: some View {
        Section {
            HStack(spacing: 16) {
                BlobTouchView(mood: store.isConnected ? (store.waitingCount > 0 ? .attention : .idle) : .sleeping,
                              logos: Account.orbitLogos(store.accounts))
                    .frame(width: 76, height: 76)
                VStack(alignment: .leading, spacing: 4) {
                    Text(store.macName).font(.title3.bold())
                    Text(store.isConnected ? "Connected" : (store.connectionError ?? "Not connected"))
                        .font(.subheadline)
                        .foregroundStyle(store.isConnected ? .green : .secondary)
                        .lineLimit(3)
                    if let hub = store.hub {
                        Text("Agent Hub \(hub.version) · \(hub.user)").font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.vertical, 6)
        }
    }

    private var connection: some View {
        Section {
            if let host = store.connectedHost {
                LabeledContent("Address", value: host)
            }
            if let latency = store.client.latency {
                LabeledContent("Round Trip", value: latency.formatted(.units(allowed: [.milliseconds], width: .abbreviated)))
            }
            if let hub = store.hub, let name = hub.tailscaleName {
                LabeledContent("Tailnet Name", value: name)
            }
            Button("Reconnect", systemImage: "arrow.clockwise") { Task { await store.connect() } }
            Button("Pair With a Link…", systemImage: "link") { showingPairing = true }
        } header: {
            Text("Connection")
        } footer: {
            Text("Over Tailscale, from anywhere. Only devices signed in to your tailnet as you, with this pairing, can connect.")
        }
    }

    @ViewBuilder private var permissions: some View {
        if let hub = store.hub {
            Section {
                Toggle(isOn: Binding(get: { store.screenSharing }, set: { on in
                    Task { _ = await store.setScreenSharing(on) }
                })) {
                    Label {
                        Text("Live Screen")
                        Text(store.screenSharing ? "The Screen tab can show and control the Mac" : "Off: the Mac's screen isn't recorded")
                    } icon: {
                        Image(systemName: store.screenSharing ? "video.fill" : "video.slash")
                    }
                }
            } header: {
                Text("Screen")
            } footer: {
                Text("Turn it off and Agent Hub stops recording your Mac's screen for every phone, until it's turned on again.")
            }
            Section {
                PermissionRow(title: "Screen Recording", detail: "Live screen", allowed: hub.screenRecording) {
                    Task { await request("screen") }
                }
                PermissionRow(title: "Accessibility", detail: "Taps, typing and full-screen windows", allowed: hub.accessibility) {
                    Task { await request("accessibility") }
                }
                LabeledContent("Terminal sessions", value: hub.tmuxPath == nil ? "tmux missing" : "Ready")
            } header: {
                Text("On the Mac")
            } footer: {
                Text("macOS asks on the Mac. You can answer from the Screen tab: tap the switch in System Settings.")
            }
        }
    }

    private var accounts: some View {
        Section {
            ForEach(store.accounts) { account in
                NavigationLink {
                    HistoryList(account: account, onPick: nil)
                } label: {
                    HStack(spacing: 12) {
                        ProviderGlyph(account: account, provider: account.provider, size: 34)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(account.name)
                            Text(account.command.isEmpty ? "Shell" : account.command)
                                .font(.footnote.monospaced())
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        let running = store.sessions.count(where: { $0.accountId == account.id && $0.state != .ended })
                        if running > 0 {
                            Text("\(running) running").font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
                .disabled(account.provider == .shell)
            }
        } header: {
            Text("Accounts")
        } footer: {
            Text("Each account runs exactly as you'd type it in Terminal, with its own sign-in. Add or rename them in ~/.agenthub/config.json on the Mac.")
        }
    }

    private var signing: some View {
        Section {
            if let expiry = SigningInfo.expiration {
                LabeledContent("This Build Works Until") {
                    VStack(alignment: .trailing) {
                        Text(expiry, format: .dateTime.weekday().day().month().hour().minute())
                        Text(expiry, format: .relative(presentation: .named))
                            .font(.footnote)
                            .foregroundStyle(expiry.timeIntervalSinceNow < 86_400 ? .orange : .secondary)
                    }
                }
            } else {
                LabeledContent("This Build", value: "Development")
            }
            if let renewal = store.hub?.renewal {
                if let last = renewal.lastAttempt {
                    LabeledContent("Last Renewal") {
                        VStack(alignment: .trailing) {
                            Text(last, format: .relative(presentation: .named))
                            if let result = renewal.lastResult {
                                Text(result).font(.footnote).foregroundStyle(renewal.lastSucceeded == false ? .red : .secondary)
                                    .multilineTextAlignment(.trailing)
                            }
                        }
                    }
                }
                Button {
                    Task { await renew() }
                } label: {
                    Label(renewal.running || renewing ? "Renewing on the Mac…" : "Renew Now", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(renewal.running || renewing)
                Toggle("Renew Automatically", systemImage: "clock.arrow.circlepath", isOn: Binding(
                    get: { renewal.autoRenew ?? true },
                    set: { on in Task { await setAutoRenew(on) } }))
            }
        } header: {
            Text("Signing")
        } footer: {
            Text("Signed with your own Apple ID, so each install lasts 7 days. The Mac renews it on its own before it runs out, whenever this iPhone is nearby on the same Wi-Fi or plugged in.")
        }
    }

    /// How a session that needs you gets your attention: a picker of styles, each tried as it's chosen.
    @ViewBuilder private var alertStyle: some View {
        Section {
            ForEach(AlertStyle.allCases) { style in
                Button {
                    alertStyleRaw = style.rawValue
                    AttentionNotifier.shared.test(style: style, store: store)
                } label: {
                    HStack(spacing: 14) {
                        Image(systemName: style.symbol)
                            .font(.title3)
                            .foregroundStyle(.tint)
                            .frame(width: 30)
                            .symbolEffect(.bounce, value: alertStyleRaw == style.rawValue)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(style.title)
                            Text(style.detail).font(.footnote).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if alertStyleRaw == style.rawValue {
                            Image(systemName: "checkmark").font(.body.weight(.semibold)).foregroundStyle(.tint)
                        }
                    }
                    .contentShape(.rect)
                    .frame(minHeight: 44)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(alertStyleRaw == style.rawValue ? .isSelected : [])
            }
        } header: {
            Text("When a Session Needs You")
        } footer: {
            Text("In the app: a banner at the top. Outside it: a notification with the agent's own answers as buttons, after Face ID. Choosing a style plays it.")
        }
        Section {
            Toggle(isOn: $liveActivity) {
                Label {
                    Text("Live Activity")
                    Text("The session that needs you on the Lock Screen and in the Dynamic Island")
                } icon: {
                    Image(systemName: "inset.filled.capsule")
                }
            }
            .onChange(of: liveActivity) { _, on in
                if on {
                    LiveActivityController.shared.update(sessions: store.sessions, accounts: store.accounts, macName: store.macName)
                } else {
                    LiveActivityController.shared.end(immediately: true)
                }
            }
            Toggle(isOn: $stayConnected) {
                Label {
                    Text("Stay Connected")
                    Text("Keeps Agent Hub running after you leave it, so alerts and the island stay live. Uses more battery.")
                } icon: {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                }
            }
        } header: {
            Text("Lock Screen and Dynamic Island")
        } footer: {
            Text("A free Apple ID can't use Apple's push service, so iOS lets Agent Hub update the island while it's running: open, for half a minute after you leave it, or always with Stay Connected. Force-quitting it stops this; ntfy still alerts you.")
        }
    }

    private var alerts: some View {
        Section {
            TextField("https://ntfy.sh/your-private-topic", text: $ntfy)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
            Button("Save", systemImage: "bell.badge") {
                Task {
                    await store.perform {
                        let _: OKResult = try await store.client.request("mac.ntfy", ["url": ntfy])
                    }
                    store.toast = ToastEvent(message: ntfy.isEmpty ? "Alerts turned off." : "Alerts go to your ntfy topic.", level: "info")
                }
            }
        } header: {
            Text("Alerts While the App Is Closed")
        } footer: {
            Text("A free Apple ID can't receive push notifications. With the ntfy app subscribed to a private topic, your Mac alerts you when a session needs you and no phone is connected. Leave empty to turn off.")
        }
    }

    private var about: some View {
        Section {
            HStack(alignment: .top, spacing: 12) {
                BlobView(mood: .happy, logos: Account.orbitLogos(store.accounts)).frame(width: 64, height: 64)
                Text("Agent Hub's mascot is a Starlight blob from bloub (MIT), an open-source avatar engine. Around it fly the agents it looks after, with the logos their own CLIs draw.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func request(_ kind: String) async {
        do {
            let result: OKResult = try await store.client.request(Method.macPermission, PermissionParams(kind: kind))
            store.toast = ToastEvent(message: result.message ?? "Asked on the Mac.", level: "info")
        } catch {
            store.toast = ToastEvent(message: HubClient.describe(error), level: "error")
        }
    }

    private func setAutoRenew(_ on: Bool) async {
        await store.perform {
            let _: HubInfo = try await store.client.request(Method.macRenewAuto, ScreenSharingParams(enabled: on))
            await store.refreshHub()
        }
    }

    private func renew() async {
        renewing = true
        defer { renewing = false }
        do {
            let result: OKResult = try await store.client.request(Method.macRenew, Empty())
            store.toast = ToastEvent(message: result.message ?? "Renewing.", level: "info")
            try? await Task.sleep(for: .seconds(3))
            await store.refreshHub()
        } catch {
            store.toast = ToastEvent(message: HubClient.describe(error), level: "error")
        }
    }
}

struct PermissionRow: View {
    var title: String
    var detail: String
    var allowed: Bool
    var request: () -> Void

    var body: some View {
        HStack {
            Image(systemName: allowed ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(allowed ? .green : .orange)
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.footnote).foregroundStyle(.secondary)
            }
            Spacer()
            if !allowed {
                Button("Ask", action: request).buttonStyle(.bordered)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(allowed ? "Allowed" : "Not allowed")
    }
}

/// Paste the pairing link from the Mac's menu bar to connect this phone (or to re-pair after a new token).
struct PairingSheet: View {
    @Environment(HubStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var link = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("agenthub://pair?…", text: $link, axis: .vertical)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .lineLimit(2...5)
                    PasteButton(payloadType: String.self) { strings in
                        link = strings.first ?? ""
                    }
                } footer: {
                    Text("On the Mac, open Agent Hub in the menu bar and choose Copy Pairing Link. With Universal Clipboard, paste it here.")
                }
            }
            .navigationTitle("Pair With Your Mac")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Pair", systemImage: "link") {
                        Task {
                            if let url = URL(string: link.trimmingCharacters(in: .whitespacesAndNewlines)),
                               await store.applyPairing(url) {
                                dismiss()
                            } else {
                                store.toast = ToastEvent(message: "That isn't a complete pairing link.", level: "error")
                            }
                        }
                    }
                    .disabled(link.isEmpty)
                }
            }
        }
    }
}
