import AppKit
import SwiftUI

/// The iPhone app's 7-day signing in the menu bar: the days left, the end
/// date, what happens next, the last result, Renew Now and Renew Automatically.
struct RenewalSection: View {
    @Bindable var hub: Hub
    @State private var reach: PhoneReach = .checking

    private var renewal: RenewalInfo? { hub.renewal }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("iPhone App").font(.subheadline.bold())
                Spacer()
                if let renewal {
                    Text(RenewalWords.daysLeft(renewal))
                        .font(.subheadline.monospacedDigit().weight(.semibold))
                        .foregroundStyle(RenewalWords.urgent(renewal) ? .orange : .secondary)
                }
            }
            if let renewal {
                if let expires = renewal.expiresAt {
                    Label(RenewalWords.expiresLine(expires), systemImage: "calendar")
                }
                Label(RenewalWords.nextLine(renewal, reach: reach), systemImage: renewal.running ? "arrow.triangle.2.circlepath" : "clock")
                    .foregroundStyle(.secondary)
                if let last = RenewalWords.lastLine(renewal) {
                    Label {
                        Text(last)
                    } icon: {
                        Image(systemName: renewal.lastSucceeded == false ? "exclamationmark.triangle.fill" : "checkmark.seal")
                            .foregroundStyle(renewal.lastSucceeded == false ? .orange : .green)
                    }
                    .foregroundStyle(renewal.lastSucceeded == false ? .primary : .secondary)
                }
                Label(reach.words, systemImage: reach.symbol)
                    .foregroundStyle(reach.isProblem ? .orange : .secondary)
                HStack(spacing: 10) {
                    Button {
                        renewNow()
                    } label: {
                        Label(renewal.running ? "Renewing…" : "Renew Now", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .disabled(renewal.running)
                    .help("Build Agent Hub and install it on your iPhone now. It needs the iPhone nearby and Xcode signed in.")
                    Toggle("Renew Automatically", isOn: Binding(get: { renewal.autoRenew ?? true }, set: { on in
                        RenewalState.setAutomatic(on)
                        hub.refreshRenewal()
                    }))
                    .toggleStyle(.checkbox)
                    .help("Renews by itself within 30 hours of the end date, whenever the iPhone is reachable.")
                }
                .controlSize(.small)
            }
        }
        .font(.callout)
        .task(id: renewal?.running) {
            reach = .checking
            reach = await PhoneReach.check()
        }
    }

    private func renewNow() {
        do {
            try RenewalState.start(repoPath: hub.config.repoPath, reason: "menu")
            hub.refreshRenewal()
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't start the renewal"
            alert.informativeText = (error as? WireError)?.message ?? error.localizedDescription
            alert.runModal()
        }
    }
}

/// Words for the signing.
enum RenewalWords {
    /// "7 days", "1 day", "20 hours", "Expired", "Renewing…".
    static func daysLeft(_ renewal: RenewalInfo, now: Date = .now) -> String {
        if renewal.running { return "Renewing…" }
        guard let expires = renewal.expiresAt else { return "No date" }
        let seconds = expires.timeIntervalSince(now)
        if seconds <= 0 { return "Expired" }
        let days = Int(seconds / 86_400)
        if days >= 1 { return days == 1 ? "1 day" : "\(days) days" }
        let hours = max(1, Int(seconds / 3600))
        return hours == 1 ? "1 hour" : "\(hours) hours"
    }

    /// Worth a look: a day or less left, expired, or the last try failed.
    static func urgent(_ renewal: RenewalInfo, now: Date = .now) -> Bool {
        if renewal.lastSucceeded == false { return true }
        guard let expires = renewal.expiresAt else { return false }
        return expires.timeIntervalSince(now) <= 86_400
    }

    /// The menu bar's text next to the blob: only when it needs you.
    static func badge(_ renewal: RenewalInfo?, now: Date = .now) -> String? {
        guard let renewal else { return nil }
        if renewal.running { return "Renewing…" }
        return urgent(renewal, now: now) ? daysLeft(renewal, now: now) : nil
    }

    static func expiresLine(_ expires: Date, now: Date = .now) -> String {
        "\(expires < now ? "Expired" : "Expires") \(moment(expires, now: now))"
    }

    static func nextLine(_ renewal: RenewalInfo, reach: PhoneReach, now: Date = .now) -> String {
        if renewal.running { return "Renewing now: building and installing on your iPhone" }
        guard let expires = renewal.expiresAt else { return "Not installed by the renewal script yet: choose Renew Now" }
        if renewal.autoRenew == false { return "Automatic renewal is off: choose Renew Now before it expires" }
        if renewal.lastSucceeded == false, let last = renewal.lastAttempt, now.timeIntervalSince(last) < 45 * 60 {
            return "Tries again after \(last.addingTimeInterval(45 * 60).formatted(date: .omitted, time: .shortened))"
        }
        let start = expires.addingTimeInterval(-30 * 3600)
        if start > now { return "Renews by itself from \(moment(start, now: now))" }
        if case .unreachable = reach { return "Renews when your iPhone is reachable" }
        return "Renews at the next check (every 30 minutes)"
    }

    /// "Renewed today at 20:25", or "Couldn't renew today at 09:14: <why>".
    static func lastLine(_ renewal: RenewalInfo, now: Date = .now) -> String? {
        guard let last = renewal.lastAttempt else { return nil }
        if renewal.lastSucceeded == false {
            return "Couldn't renew \(moment(last, now: now)): \(renewal.lastResult ?? "see the log")"
        }
        return "Renewed \(moment(last, now: now))"
    }

    /// "today at 20:25", "yesterday at 09:14", "Sun 8 Nov at 18:48".
    static func moment(_ date: Date, now: Date = .now) -> String {
        let calendar = Calendar.current
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDate(date, inSameDayAs: now) { return "today at \(time)" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "yesterday at \(time)"
        }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) {
            return "tomorrow at \(time)"
        }
        return "\(date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))) at \(time)"
    }
}

/// Whether the iPhone the app was installed on can be reached for a renewal right now (`devicectl`, as renew.sh
/// checks it).
enum PhoneReach: Equatable {
    case checking
    case reachable(String)
    case unreachable
    case unknown

    var words: String {
        switch self {
        case .checking: "Checking your iPhone…"
        case .reachable(let how): "iPhone reachable \(how)"
        case .unreachable: "iPhone not reachable: unlock it on the same Wi-Fi as this Mac, or plug it in"
        case .unknown: "Couldn't check the iPhone (Xcode's device tools didn't answer)"
        }
    }

    var symbol: String {
        switch self {
        case .checking: "iphone"
        case .reachable: "iphone.radiowaves.left.and.right"
        case .unreachable: "iphone.slash"
        case .unknown: "questionmark.circle"
        }
    }

    var isProblem: Bool { self == .unreachable }

    static func check() async -> PhoneReach {
        let file = FileManager.default.temporaryDirectory.appending(path: "agenthub-devices-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        var environment = ProcessInfo.processInfo.environment
        environment["DEVELOPER_DIR"] = "/Applications/Xcode.app/Contents/Developer"
        _ = await Shell.run("/usr/bin/xcrun", ["devicectl", "list", "devices", "--json-output", file.path],
                            environment: environment, timeout: 30)
        guard let data = try? Data(contentsOf: file),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let devices = (json["result"] as? [String: Any])?["devices"] as? [[String: Any]] else { return .unknown }
        func field(_ device: [String: Any], _ path: String...) -> String? {
            var value: Any? = device
            for key in path { value = (value as? [String: Any])?[key] }
            return value as? String
        }
        let phones = devices.filter {
            field($0, "hardwareProperties", "platform") == "iOS" && field($0, "connectionProperties", "pairingState") == "paired"
                && field($0, "connectionProperties", "transportType") != "sameMachine"
        }
        // The iPhone renew.sh installed on, else the only one.
        var wanted: String?
        if let data = FileManager.default.contents(atPath: HubPaths.renewState),
           let state = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            wanted = state["device"] as? String
        }
        guard let phone = phones.first(where: { $0["identifier"] as? String == wanted }) ?? (phones.count == 1 ? phones.first : nil)
        else { return .unreachable }
        guard field(phone, "connectionProperties", "tunnelState") == "connected" else { return .unreachable }
        return .reachable(field(phone, "connectionProperties", "transportType") == "wired" ? "by cable" : "over Wi-Fi")
    }
}
