import SwiftUI

/// A small status light in the toolbar: green when the Mac answers, with the round trip.
struct ConnectionBadge: View {
    @Environment(HubStore.self) private var store

    var body: some View {
        Menu {
            Section(store.macName) {
                if let host = store.connectedHost {
                    Label("Connected via \(host.hasPrefix("100.") || host.hasSuffix(".ts.net") ? "Tailscale" : host)",
                          systemImage: "network")
                    if let latency = store.client.latency {
                        Label("\(latency.formatted(.units(allowed: [.milliseconds], width: .abbreviated))) round trip",
                              systemImage: "timer")
                    }
                } else {
                    Label(store.connectionError ?? "Not connected", systemImage: "wifi.slash")
                }
            }
            Button("Reconnect", systemImage: "arrow.clockwise") { Task { await store.connect() } }
        } label: {
            // Toolbars draw symbols in one colour, so the state is in the symbol's shape (and in the subtitle).
            Label(store.isConnected ? "Connected" : "Offline",
                  systemImage: store.isConnected ? "dot.radiowaves.left.and.right" : (store.isConnecting ? "arrow.triangle.2.circlepath" : "wifi.slash"))
                .symbolEffect(.rotate, isActive: store.isConnecting)
        }
        .accessibilityLabel(store.isConnected ? "Connected to \(store.macName)" : "Not connected")
    }
}

/// Shown when the Mac can't be reached: the blob asleep (or busy while connecting), what to check, and Try Again.
struct NotConnectedView: View {
    @Environment(HubStore.self) private var store

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                BlobTouchView(mood: store.isConnecting ? .working : .sleeping, logos: Account.orbitLogos(store.accounts))
                    .frame(width: 150, height: 150)
                    .padding(.top, 40)
                Text(store.isConnecting ? "Connecting to \(store.macName)…" : "Can't reach \(store.macName)")
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)
                if let error = store.connectionError, !store.isConnecting {
                    Text(error)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                VStack(alignment: .leading, spacing: 12) {
                    Label("Tailscale is on, on this iPhone and on the Mac", systemImage: "point.3.filled.connected.trianglepath.dotted")
                    Label("The Mac is awake, with Agent Hub in its menu bar", systemImage: "menubar.rectangle")
                    Label("Both are signed in to the same tailnet", systemImage: "person.badge.key")
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding()
                .background(.fill.quaternary, in: .rect(cornerRadius: Theme.cardRadius))
                Button {
                    Task { await store.connect() }
                } label: {
                    Label("Try Again", systemImage: "arrow.clockwise")
                        .frame(maxWidth: 280)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .disabled(store.isConnecting)
            }
            .padding()
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
        }
    }
}

/// No sessions yet: the blob with its agents, and the button to start one.
struct EmptySessionsView: View {
    @Environment(HubStore.self) private var store
    var start: () -> Void

    var body: some View {
        ContentUnavailableView {
            BlobTouchView(mood: .idle, logos: Account.orbitLogos(store.accounts))
                .frame(width: 130, height: 130)
            Text("No Sessions Yet")
        } description: {
            Text("Start Claude, Codex, OpenCode or Antigravity in any folder on your Mac. Each session opens in its own full-screen Terminal window there.")
        } actions: {
            Button("New Session", systemImage: "plus", action: start)
                .buttonStyle(.glassProminent)
        }
    }
}
