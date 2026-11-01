import Foundation

/// The coding agent behind an account. Each one stores its conversations differently, so the hub reads each kind
/// with its own transcript reader.
nonisolated public enum ProviderKind: String, Codable, Sendable, CaseIterable, Hashable {
    case claude
    case codex
    case opencode
    case antigravity
    case gemini
    case shell
    /// Any other terminal agent (Aider, Goose, Amp, Cursor Agent, ...): it runs in the terminal view, and its logo is
    /// read from its own screen like every other agent's.
    case other

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ProviderKind(rawValue: raw) ?? .other
    }

    public var displayName: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .opencode: "OpenCode"
        case .antigravity: "Antigravity"
        case .gemini: "Gemini CLI"
        case .shell: "Shell"
        case .other: "Agent"
        }
    }

    /// Whether the hub can read this agent's conversation into a chat timeline (otherwise the terminal is shown).
    public var hasStructuredTranscript: Bool {
        switch self {
        case .claude, .codex, .opencode: true
        case .antigravity, .gemini, .shell, .other: false
        }
    }

    /// Permission modes the agent accepts at launch, in the agent's own words.
    public var launchModes: [LaunchMode] {
        switch self {
        case .claude:
            [
                LaunchMode(id: "", title: "Ask before acting", detail: "Claude asks before edits and commands."),
                LaunchMode(id: "acceptEdits", title: "Accept edits", detail: "Edits are applied; commands still ask."),
                LaunchMode(id: "plan", title: "Plan mode", detail: "Claude plans first and changes nothing."),
                LaunchMode(id: "auto", title: "Auto", detail: "Claude decides what is safe to run."),
                LaunchMode(id: "bypassPermissions", title: "Bypass permissions", detail: "Nothing asks. Use with care."),
            ]
        case .codex:
            [
                LaunchMode(id: "", title: "Default", detail: "Codex asks when it needs to."),
                LaunchMode(id: "workspace-write", title: "Work in this folder",
                           detail: "Edits and runs in the folder; asks for anything outside it."),
                LaunchMode(id: "approve-for-me", title: "Automatic review",
                           detail: "Codex's reviewer answers approval requests for you."),
                LaunchMode(id: "read-only", title: "Read only", detail: "Codex can read but not change files."),
                LaunchMode(id: "yolo", title: "No sandbox, no approvals", detail: "Nothing asks. Use with care."),
            ]
        case .antigravity:
            [
                LaunchMode(id: "", title: "Default", detail: "Antigravity asks before acting."),
                LaunchMode(id: "accept-edits", title: "Accept edits", detail: "Edits are applied without asking."),
                LaunchMode(id: "plan", title: "Plan mode", detail: "Plans first."),
                LaunchMode(id: "skip", title: "Skip permissions", detail: "Nothing asks. Use with care."),
            ]
        case .gemini:
            [
                LaunchMode(id: "", title: "Default", detail: "Gemini asks before acting."),
                LaunchMode(id: "auto_edit", title: "Auto edit", detail: "Edits are applied without asking."),
                LaunchMode(id: "yolo", title: "YOLO", detail: "Nothing asks. Use with care."),
            ]
        case .opencode, .shell, .other:
            []
        }
    }

    /// Slash commands offered in the composer's menu. The agent itself decides what they do.
    public var slashCommands: [SlashCommand] {
        switch self {
        case .claude:
            [
                SlashCommand("/compact", "Summarise and free up context"),
                SlashCommand("/clear", "Start a fresh conversation"),
                SlashCommand("/context", "Show context usage"),
                SlashCommand("/usage", "Show plan usage and limits"),
                SlashCommand("/cost", "Show token cost"),
                SlashCommand("/model", "Choose the model"),
                SlashCommand("/status", "Show account and session status"),
                SlashCommand("/agents", "Manage subagents"),
                SlashCommand("/tasks", "Show background tasks"),
                SlashCommand("/todos", "Show the to-do list"),
                SlashCommand("/review", "Review a pull request"),
                SlashCommand("/rewind", "Rewind the conversation or code"),
                SlashCommand("/resume", "Resume another conversation"),
                SlashCommand("/memory", "Edit memory files"),
                SlashCommand("/mcp", "Manage MCP servers"),
                SlashCommand("/permissions", "Manage tool permissions"),
                SlashCommand("/init", "Create a CLAUDE.md for this folder"),
                SlashCommand("/export", "Export the conversation"),
                SlashCommand("/doctor", "Check the installation"),
                SlashCommand("/help", "Show help"),
            ]
        case .codex:
            [
                SlashCommand("/model", "Choose the model and effort"),
                SlashCommand("/approvals", "Choose what Codex may do without asking"),
                SlashCommand("/status", "Show session status and limits"),
                SlashCommand("/diff", "Show the git diff"),
                SlashCommand("/compact", "Summarise to free up context"),
                SlashCommand("/review", "Review current changes"),
                SlashCommand("/new", "Start a new conversation"),
                SlashCommand("/resume", "Resume a saved conversation"),
                SlashCommand("/init", "Create an AGENTS.md"),
                SlashCommand("/mcp", "List MCP tools"),
                SlashCommand("/mention", "Mention a file"),
                SlashCommand("/quit", "Exit Codex"),
            ]
        case .opencode:
            [
                SlashCommand("/new", "Start a new session"),
                SlashCommand("/sessions", "List sessions"),
                SlashCommand("/models", "Choose the model"),
                SlashCommand("/agents", "Choose the agent"),
                SlashCommand("/compact", "Summarise the session"),
                SlashCommand("/undo", "Undo the last message"),
                SlashCommand("/redo", "Redo"),
                SlashCommand("/share", "Share the session"),
                SlashCommand("/help", "Show help"),
                SlashCommand("/exit", "Exit OpenCode"),
            ]
        case .antigravity, .gemini:
            [
                SlashCommand("/help", "Show help"),
                SlashCommand("/model", "Choose the model"),
                SlashCommand("/compress", "Summarise the conversation"),
                SlashCommand("/clear", "Clear the screen"),
                SlashCommand("/stats", "Show usage"),
                SlashCommand("/quit", "Exit"),
            ]
        case .shell, .other:
            []
        }
    }
}

nonisolated public struct LaunchMode: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var title: String
    public var detail: String

    public init(id: String, title: String, detail: String) {
        self.id = id
        self.title = title
        self.detail = detail
    }
}

nonisolated public struct SlashCommand: Codable, Sendable, Hashable, Identifiable {
    public var id: String { command }
    public var command: String
    public var detail: String

    public init(_ command: String, _ detail: String) {
        self.command = command
        self.detail = detail
    }
}

/// One agent account on the Mac: a command the person runs in their own shell (`claude-w`, `codex`, ...), and where
/// that account keeps its conversations.
nonisolated public struct Account: Codable, Sendable, Identifiable, Hashable {
    public var id: String
    public var name: String
    public var provider: ProviderKind
    /// What the person types in their terminal. It runs in their interactive login shell, so shell functions and
    /// aliases such as `claude-w` work exactly as they do by hand.
    public var command: String
    /// Where this account keeps its data (Claude's `CLAUDE_CONFIG_DIR`, Codex's `CODEX_HOME`, OpenCode's data folder).
    public var dataDir: String?
    /// A short tag shown on the provider glyph, such as "W" or "P".
    public var badge: String?
    public var available: Bool
    public var detail: String?
    /// The CLI's logo as it draws it in the terminal, read by the hub from the CLI's own screen.
    public var logo: TerminalLogo?

    public init(id: String, name: String, provider: ProviderKind, command: String, dataDir: String?, badge: String?,
                available: Bool, detail: String?, logo: TerminalLogo? = nil) {
        self.id = id
        self.name = name
        self.provider = provider
        self.command = command
        self.dataDir = dataDir
        self.badge = badge
        self.available = available
        self.detail = detail
        self.logo = logo
    }
}

/// A CLI's logo, cut out of its own terminal screen: lines of characters with their ANSI colour codes.
nonisolated public struct TerminalLogo: Codable, Sendable, Hashable {
    /// A compact, roughly square mark for icons.
    public var mark: [String]
    /// The whole logo as drawn (for example a full wordmark).
    public var full: [String]
    /// "art" (block characters) or "text" (a coloured symbol before the product name, like ">_").
    public var source: String
    public var capturedAt: Date

    public init(mark: [String], full: [String], source: String, capturedAt: Date) {
        self.mark = mark
        self.full = full
        self.source = source
        self.capturedAt = capturedAt
    }
}

public extension Account {
    /// One logo per agent for the mascot's orbit: Claude, Codex, Antigravity, OpenCode, then any other (first
    /// account of each with a logo its CLI drew).
    static func orbitLogos(_ accounts: [Account]) -> [TerminalLogo] {
        let order: [ProviderKind] = [.claude, .codex, .antigravity, .opencode, .gemini, .other]
        return order.compactMap { kind in accounts.first { $0.provider == kind && $0.logo != nil }?.logo }
    }
}
