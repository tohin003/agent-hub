import AppKit
import SwiftUI

/// The menu bar panel: is the hub reachable, what's running, what macOS still needs to allow.
struct MenuPanel: View {
    @Bindable var hub: Hub
    @State private var copied = false
    /// Why the last Restart didn't go through ("Claude Code is working…").
    @State private var restartProblem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Divider()
            sessions
            Divider()
            permissions
            Divider()
            RenewalSection(hub: hub)
            Divider()
            footer
        }
        .padding(16)
        .frame(width: 360)
        .onAppear { hub.refreshRenewal() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            BlobView(mood: hub.sessionList.contains { $0.attention != nil && $0.attention?.optional != true } ? .attention
                        : (hub.connectedDevices.isEmpty ? .idle : .working),
                     logos: Account.orbitLogos(hub.accounts))
                .frame(width: 72, height: 72)
            VStack(alignment: .leading, spacing: 2) {
                Text("Agent Hub").font(.headline)
                Text(connectionLine).font(.callout).foregroundStyle(.secondary)
                if let problem = hub.problem {
                    Text(problem).font(.callout).foregroundStyle(.red)
                }
            }
        }
    }

    private var connectionLine: String {
        if !hub.connectedDevices.isEmpty { return "Connected: \(hub.connectedDevices.joined(separator: ", "))" }
        if let ip = hub.tailnet.ipv4 { return "Waiting for your iPhone on \(hub.tailnet.dnsName ?? ip)" }
        return "Tailscale is off: only this Mac can connect"
    }

    @ViewBuilder private var sessions: some View {
        Text("Sessions").font(.subheadline.bold())
        let live = hub.sessionList.filter { $0.state != .ended }
        if live.isEmpty {
            Text("None running. Start one from the Agent Hub app on your iPhone.").font(.callout).foregroundStyle(.secondary)
        } else {
            ForEach(live.prefix(8)) { session in
                HStack {
                    Circle().fill(color(session.state)).frame(width: 8, height: 8)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(session.title).lineLimit(1)
                        Text("\(session.accountId) · \(URL(fileURLWithPath: session.cwd).lastPathComponent)")
                            .font(.caption).foregroundStyle(.secondary)
                        if session.agentUpdated == true {
                            Label("\(session.provider.displayName) was updated: restart it to open dropped files",
                                  systemImage: "arrow.triangle.2.circlepath")
                                .font(.caption).foregroundStyle(.orange)
                        }
                    }
                    Spacer()
                    if session.agentUpdated == true, session.provider == .claude {
                        Button("Restart", systemImage: "arrow.clockwise") { restart(session) }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                            .disabled(session.state == .working || session.state == .starting)
                            .help("Restart \(session.provider.displayName) to use the new version. The conversation, mode and model carry on.")
                    }
                    Button("Show", systemImage: "macwindow") {
                        Task { try? await hub.sessions?.window(WindowParams(sessionId: session.id, action: "focus")) }
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("Show this session's window")
                }
            }
            if let restartProblem {
                Text(restartProblem).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func restart(_ session: SessionInfo) {
        restartProblem = nil
        Task {
            do {
                try await hub.sessions?.restart(session.id)
            } catch {
                restartProblem = (error as? WireError)?.message ?? error.localizedDescription
            }
        }
    }

    @ViewBuilder private var permissions: some View {
        Text("This Mac").font(.subheadline.bold())
        permissionRow("Screen Recording", allowed: ScreenService.screenRecordingAllowed, detail: "for the live screen") {
            ScreenService.requestScreenRecording()
        }
        permissionRow("Accessibility", allowed: InputInjector.trusted, detail: "for taps, keys and full-screen windows") {
            ScreenService.requestAccessibility()
        }
    }

    private func permissionRow(_ title: String, allowed: Bool, detail: String, action: @escaping () -> Void) -> some View {
        HStack {
            Image(systemName: allowed ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(allowed ? .green : .orange)
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !allowed {
                Button("Allow…", action: action)
            }
        }
    }

    private var footer: some View {
        HStack {
            Button(copied ? "Copied" : "Copy Pairing Link", systemImage: copied ? "checkmark" : "link") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(hub.pairingLink, forType: .string)
                copied = true
            }
            .help("Paste it into Agent Hub on your iPhone (Mac tab › Pair) to connect without rebuilding.")
            Spacer()
            Button("Logs", systemImage: "doc.text.magnifyingglass") {
                NSWorkspace.shared.open(FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Logs/AgentHub"))
            }
            .labelStyle(.iconOnly)
            Button("Quit", systemImage: "power") { NSApp.terminate(nil) }
                .labelStyle(.iconOnly)
                .help("Quit Agent Hub (it starts again at your next login)")
        }
        .buttonStyle(.borderless)
    }

    private func color(_ state: SessionState) -> Color {
        switch state {
        case .working: .blue
        case .waiting: .orange
        case .idle: .green
        case .starting: .gray
        case .exited, .ended: .secondary
        }
    }
}
