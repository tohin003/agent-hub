import Foundation

/// What Claude Code's status line reports for a session the hub started (`~/.agenthub/status/<session>.json`,
/// written by `~/.agenthub/statusline.sh`): context window, plan limits, model, effort.
enum ClaudeStatus {
    static func path(_ sessionId: String) -> String { "\(HubPaths.root)/status/\(sessionId).json" }

    static func usage(from data: Data) -> SessionUsage? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var usage = SessionUsage(updatedAt: .now)
        if let context = json["context_window"] as? [String: Any] {
            let tokens = (context["total_input_tokens"] as? NSNumber)?.intValue ?? 0
            usage.contextTokens = tokens > 0 ? tokens : nil
            usage.contextWindow = (context["context_window_size"] as? NSNumber)?.intValue
            usage.contextPercent = (context["used_percentage"] as? NSNumber)?.doubleValue
        }
        if let model = json["model"] as? [String: Any] { usage.modelName = model["display_name"] as? String }
        if let effort = json["effort"] as? [String: Any] { usage.effort = effort["level"] as? String }
        if let cost = json["cost"] as? [String: Any] { usage.costUSD = (cost["total_cost_usd"] as? NSNumber)?.doubleValue }
        if let limits = json["rate_limits"] as? [String: Any] {
            for (key, name) in [("five_hour", "Current session"), ("seven_day", "Current week")] {
                guard let limit = limits[key] as? [String: Any],
                      let percent = (limit["used_percentage"] as? NSNumber)?.doubleValue else { continue }
                let resets = (limit["resets_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
                usage.limits.append(UsageLimit(name: name, percent: percent, resetsAt: resets))
            }
        }
        return usage
    }
}

/// Claude Code's `/usage` as text (`claude -p /usage`): its limits, and what's contributing to them.
enum ClaudeUsageText {
    private static let limitRegex = try! NSRegularExpression(
        pattern: #"^(.+?):\s*(\d+(?:\.\d+)?)%\s*used(?:\s*[·•-]\s*resets\s+(.+))?$"#, options: [.caseInsensitive])
    private static let tipRegex = try! NSRegularExpression(pattern: #"^(\d+(?:\.\d+)?)%\s+(.+)$"#)

    /// "Current session: 38% used · resets Nov 1 at 10:30pm (Asia/Calcutta)", then "What's contributing to your
    /// usage?" with a section per period.
    static func parse(_ text: String, accountId: String, now: Date = .now) -> AccountUsage {
        var limits: [UsageLimit] = []
        var notes: [String] = []
        var sections: [UsageSection] = []
        var inSections = false
        let noise = ["restored session:", "saving session", "...saving", "...completed", "...truncating"]
        for raw in text.components(separatedBy: .newlines) {
            let line = PaneReader.cleanEscapes(raw).trimmingTrailingWhitespace()
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !noise.contains(where: { trimmed.lowercased().hasPrefix($0) }) else { continue }
            let ns = trimmed as NSString
            let range = NSRange(location: 0, length: ns.length)
            if !inSections, let match = limitRegex.firstMatch(in: trimmed, range: range) {
                let name = ns.substring(with: match.range(at: 1))
                let percent = Double(ns.substring(with: match.range(at: 2))) ?? 0
                let resets = match.range(at: 3).location != NSNotFound ? ns.substring(with: match.range(at: 3)) : nil
                limits.append(UsageLimit(name: name, percent: percent, resetsAt: resets.flatMap { resetDate($0, now: now) },
                                         resetsText: resets))
                continue
            }
            if trimmed.lowercased().hasPrefix("what's contributing") || trimmed.lowercased().hasPrefix("what’s contributing") {
                inSections = true
                continue
            }
            guard inSections else {
                notes.append(trimmed)
                continue
            }
            let indented = line.hasPrefix(" ")
            if !indented {
                if sections.isEmpty, trimmed.lowercased().hasPrefix("approximate") {
                    notes.append(trimmed)
                } else {
                    sections.append(UsageSection(title: trimmed, lines: []))
                }
                continue
            }
            guard !sections.isEmpty else { continue }
            if let match = tipRegex.firstMatch(in: trimmed, range: range) {
                sections[sections.count - 1].lines.append(UsageLine(percent: Double(ns.substring(with: match.range(at: 1))),
                                                                    text: ns.substring(with: match.range(at: 2))))
            } else {
                sections[sections.count - 1].lines.append(UsageLine(percent: nil, text: trimmed))
            }
        }
        return AccountUsage(accountId: accountId, limits: limits, notes: notes, sections: sections, fetchedAt: now)
    }

    /// "Nov 1 at 10:30pm (Asia/Calcutta)", "Nov 6 at 7:30am", "10pm (Asia/Calcutta)".
    static func resetDate(_ text: String, now: Date) -> Date? {
        var body = text
        var zone = TimeZone.current
        if let open = text.lastIndex(of: "("), let close = text.lastIndex(of: ")"), open < close {
            if let named = TimeZone(identifier: String(text[text.index(after: open)..<close])) { zone = named }
            body = String(text[..<open]).trimmingCharacters(in: .whitespaces)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = zone
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        for format in ["MMM d 'at' h:mma", "MMM d 'at' ha", "MMM d, h:mma", "MMM d"] {
            formatter.dateFormat = format
            guard let parsed = formatter.date(from: body) else { continue }
            var parts = calendar.dateComponents([.month, .day, .hour, .minute], from: parsed)
            parts.year = calendar.component(.year, from: now)
            guard var date = calendar.date(from: parts) else { continue }
            if date < now.addingTimeInterval(-86_400 * 180) { date = calendar.date(byAdding: .year, value: 1, to: date) ?? date }
            return date
        }
        for format in ["h:mma", "ha"] {
            formatter.dateFormat = format
            guard let parsed = formatter.date(from: body) else { continue }
            let time = calendar.dateComponents([.hour, .minute], from: parsed)
            guard var date = calendar.date(bySettingHour: time.hour ?? 0, minute: time.minute ?? 0, second: 0, of: now) else { continue }
            if date < now { date = calendar.date(byAdding: .day, value: 1, to: date) ?? date }
            return date
        }
        return nil
    }

}

/// Context window sizes as Claude Code writes them: "**Tokens:** 21.1k / 1m (2%)" (`claude -p /context`),
/// "41.4k/1m tokens (4%)" (its terminal).
enum ContextText {
    private static let patterns = [
        try! NSRegularExpression(pattern: #"Tokens:\**\s*([\d.]+)\s*([kKmM]?)\s*/\s*([\d.]+)\s*([kKmM]?)"#),
        try! NSRegularExpression(pattern: #"([\d.]+)\s*([kKmM]?)\s*/\s*([\d.]+)\s*([kKmM]?)\s+tokens"#),
    ]

    /// The window: the number after the slash.
    static func window(_ text: String) -> Int? {
        let ns = text as NSString
        for pattern in patterns {
            guard let match = pattern.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { continue }
            return number(ns.substring(with: match.range(at: 3)), ns.substring(with: match.range(at: 4)))
        }
        return nil
    }

    static func number(_ value: String, _ suffix: String) -> Int? {
        guard let number = Double(value) else { return nil }
        switch suffix.lowercased() {
        case "k": return Int(number * 1_000)
        case "m": return Int(number * 1_000_000)
        default: return Int(number)
        }
    }
}

extension ClaudeStatus {
    /// The model and its window, from the status line: learnt for sessions that don't have one.
    static func modelWindow(from data: Data) -> (model: String, window: Int)? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let model = (json["model"] as? [String: Any])?["id"] as? String,
              let window = ((json["context_window"] as? [String: Any])?["context_window_size"] as? NSNumber)?.intValue,
              window > 0 else { return nil }
        return (model, window)
    }
}
