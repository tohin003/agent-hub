import Foundation

// Usage, models and effort, as the agents themselves report them. Nothing here is a fixed list: Claude Code's
// status line and `/usage`, `/model` and `/effort` screens, and Codex's own logs and model cache are the sources.

/// How much of its context window a session has used, its plan limits, and the model and effort it runs with.
nonisolated public struct SessionUsage: Codable, Sendable, Hashable {
    /// Tokens in the context window now.
    public var contextTokens: Int?
    /// The model's context window.
    public var contextWindow: Int?
    /// 0–100.
    public var contextPercent: Double?
    /// Plan limits (Claude subscriptions, Codex plans), in the agent's words.
    public var limits: [UsageLimit]
    /// What the session has cost, when the agent reports it.
    public var costUSD: Double?
    /// The model's display name ("Opus 5.5", "GPT-6.1-Sol").
    public var modelName: String?
    /// The reasoning effort ("medium", "max"), when the model has one.
    public var effort: String?
    public var updatedAt: Date?

    public init(contextTokens: Int? = nil, contextWindow: Int? = nil, contextPercent: Double? = nil,
                limits: [UsageLimit] = [], costUSD: Double? = nil, modelName: String? = nil, effort: String? = nil,
                updatedAt: Date? = nil) {
        self.contextTokens = contextTokens
        self.contextWindow = contextWindow
        self.contextPercent = contextPercent
        self.limits = limits
        self.costUSD = costUSD
        self.modelName = modelName
        self.effort = effort
        self.updatedAt = updatedAt
    }
}

/// One plan limit: "Current session 38% used, resets 10:30 pm".
nonisolated public struct UsageLimit: Codable, Sendable, Hashable, Identifiable {
    public var id: String { name }
    /// "Current session", "Current week (Fable)", "5-hour limit", "Weekly limit".
    public var name: String
    /// 0–100.
    public var percent: Double
    public var resetsAt: Date?
    /// The reset as the agent wrote it, when it gave no exact time ("Nov 1 at 10:30pm (Asia/Calcutta)").
    public var resetsText: String?

    public init(name: String, percent: Double, resetsAt: Date? = nil, resetsText: String? = nil) {
        self.name = name
        self.percent = percent
        self.resetsAt = resetsAt
        self.resetsText = resetsText
    }
}

/// An account's plan usage, read from the agent (Claude Code's `/usage`).
nonisolated public struct AccountUsage: Codable, Sendable, Hashable {
    public var accountId: String
    public var limits: [UsageLimit]
    /// Lines such as "You are currently using your subscription to power your Claude Code usage".
    public var notes: [String]
    /// "What's contributing to your usage?": one section per period, each with its lines.
    public var sections: [UsageSection]
    public var fetchedAt: Date

    public init(accountId: String, limits: [UsageLimit], notes: [String], sections: [UsageSection], fetchedAt: Date) {
        self.accountId = accountId
        self.limits = limits
        self.notes = notes
        self.sections = sections
        self.fetchedAt = fetchedAt
    }
}

nonisolated public struct UsageSection: Codable, Sendable, Hashable, Identifiable {
    public var id: String { title }
    public var title: String
    public var lines: [UsageLine]

    public init(title: String, lines: [UsageLine]) {
        self.title = title
        self.lines = lines
    }
}

/// "90%  Start fresh when you switch tasks · run /clear", or a plain line.
nonisolated public struct UsageLine: Codable, Sendable, Hashable, Identifiable {
    public var id: String { (percent.map { "\($0)" } ?? "") + text }
    public var percent: Double?
    public var text: String

    public init(percent: Double?, text: String) {
        self.percent = percent
        self.text = text
    }
}

/// The models an account offers, read from its own model picker or model cache, and its effort levels.
nonisolated public struct ModelCatalog: Codable, Sendable, Hashable {
    public var accountId: String
    public var options: [ModelOption]
    /// Effort levels in order, lowest first ("low", "medium", "high", "xhigh", "max").
    public var effortLevels: [String]
    /// Where the list came from ("picker", "cache").
    public var source: String
    public var capturedAt: Date

    public init(accountId: String, options: [ModelOption], effortLevels: [String], source: String, capturedAt: Date) {
        self.accountId = accountId
        self.options = options
        self.effortLevels = effortLevels
        self.source = source
        self.capturedAt = capturedAt
    }
}

nonisolated public struct ModelOption: Codable, Sendable, Hashable, Identifiable {
    public var id: Int { number }
    /// Its number in the agent's picker (1-based), or its place in the list.
    public var number: Int
    /// "Opus 5.5", "Default (recommended)".
    public var label: String
    /// "For complex work and everyday tasks".
    public var detail: String?
    /// The account's default when the list was read (✔ in Claude Code's picker).
    public var isDefault: Bool?
    /// The model id, when the source gives one (Codex: "gpt-6.1-sol").
    public var slug: String?
    /// Effort levels this model takes, when they differ from the catalog's.
    public var effortLevels: [String]?
    public var defaultEffort: String?

    public init(number: Int, label: String, detail: String? = nil, isDefault: Bool? = nil, slug: String? = nil,
                effortLevels: [String]? = nil, defaultEffort: String? = nil) {
        self.number = number
        self.label = label
        self.detail = detail
        self.isDefault = isDefault
        self.slug = slug
        self.effortLevels = effortLevels
        self.defaultEffort = defaultEffort
    }
}

nonisolated public struct AccountParams: Codable, Sendable {
    public var accountId: String
    /// Read it again now instead of using the copy the hub keeps.
    public var refresh: Bool?

    public init(accountId: String, refresh: Bool? = nil) {
        self.accountId = accountId
        self.refresh = refresh
    }
}

/// Switches a running session's model and/or effort, through the agent's own picker.
nonisolated public struct SessionModelParams: Codable, Sendable {
    public var sessionId: String
    /// The option's number in the catalog; nil keeps the model.
    public var number: Int?
    /// The option's label, to check the picker still shows the same model there.
    public var label: String?
    /// The effort to set; nil keeps it.
    public var effort: String?
    /// Also make it the default for new sessions (Claude Code's Enter); otherwise this session only.
    public var asDefault: Bool?

    public init(sessionId: String, number: Int?, label: String?, effort: String?, asDefault: Bool? = nil) {
        self.sessionId = sessionId
        self.number = number
        self.label = label
        self.effort = effort
        self.asDefault = asDefault
    }
}

/// Turns the Mac's screen sharing (the live feed) on or off.
nonisolated public struct ScreenSharingParams: Codable, Sendable {
    public var enabled: Bool

    public init(enabled: Bool) {
        self.enabled = enabled
    }
}

/// Types text into a choice that takes your own words ("Type something."), then submits it.
nonisolated public struct AnswerTextParams: Codable, Sendable {
    public var sessionId: String
    public var signature: String
    public var optionIndex: Int
    public var text: String

    public init(sessionId: String, signature: String, optionIndex: Int, text: String) {
        self.sessionId = sessionId
        self.signature = signature
        self.optionIndex = optionIndex
        self.text = text
    }
}

/// Model ids made readable, the way the agents name them: "claude-opus-5-5" → "Opus 5.5",
/// "claude-sonnet-4-6-20260101" → "Sonnet 4.6". Other ids stay as they are.
nonisolated public enum ModelNames {
    public static func readable(_ id: String) -> String {
        guard id.hasPrefix("claude-") else { return id }
        var parts = id.dropFirst(7).split(separator: "-").map(String.init)
        if let last = parts.last, last.count == 8, last.allSatisfy(\.isNumber) { parts.removeLast() }
        let words = parts.prefix { !$0.allSatisfy(\.isNumber) }.map { $0.prefix(1).uppercased() + $0.dropFirst() }
        let version = parts.drop { !$0.allSatisfy(\.isNumber) }.joined(separator: ".")
        let name = (words + (version.isEmpty ? [] : [version])).joined(separator: " ")
        return name.isEmpty ? id : name
    }
}
