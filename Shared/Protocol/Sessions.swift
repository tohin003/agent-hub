import Foundation

/// What a session is doing, read from its terminal and transcript.
nonisolated public enum SessionState: String, Codable, Sendable, Hashable {
    /// Just created; the agent hasn't drawn its screen yet.
    case starting
    /// The agent is working (its status line offers "esc to interrupt").
    case working
    /// The agent is waiting for you: a permission prompt, a question or a choice is on screen.
    case waiting
    /// The agent is ready for the next message.
    case idle
    /// The agent exited; the terminal is back at the shell prompt.
    case exited
    /// The terminal session is gone.
    case ended

    public var isLive: Bool { self != .ended }
}

/// A terminal session on the Mac running one agent, as the phone sees it.
nonisolated public struct SessionInfo: Codable, Sendable, Identifiable, Hashable {
    public var id: String
    public var accountId: String
    public var provider: ProviderKind
    public var title: String
    public var cwd: String
    public var createdAt: Date
    public var lastActivity: Date?
    public var state: SessionState
    /// The agent's own status line while it works, such as "Pondering… (34s · ↑ 1.2k tokens)".
    public var stateDetail: String?
    public var attention: AttentionPrompt?
    /// A terminal window on the Mac shows this session.
    public var hasWindow: Bool
    /// The hub found this agent's conversation file, so the chat timeline is available.
    public var transcriptAvailable: Bool
    public var model: String?
    public var permissionMode: String?
    public var gitBranch: String?
    /// Background work still running: shells, subagents, monitors, workflows.
    public var runningTasks: Int
    public var lastMessage: String?
    /// The agent's own conversation id, used to resume it later.
    public var agentSessionId: String?
    /// Terminal grid size.
    public var columns: Int?
    public var rows: Int?
    /// Context window, plan limits, model and effort, as the agent reports them.
    public var usage: SessionUsage?
    /// What's typed in the agent's message box on the Mac (Claude Code, Codex), such as a message the agent handed
    /// back to edit. The phone's message box shows it.
    public var draft: String?
    /// Still open in this app on the Mac ("Terminal"), finishing its turn: Agent Hub takes it over after that, or
    /// now with `session.takeOverNow`.
    public var movingFrom: String?

    public init(id: String, accountId: String, provider: ProviderKind, title: String, cwd: String, createdAt: Date,
                lastActivity: Date? = nil, state: SessionState, stateDetail: String? = nil,
                attention: AttentionPrompt? = nil, hasWindow: Bool = false, transcriptAvailable: Bool = false,
                model: String? = nil, permissionMode: String? = nil, gitBranch: String? = nil, runningTasks: Int = 0,
                lastMessage: String? = nil, agentSessionId: String? = nil, columns: Int? = nil, rows: Int? = nil,
                usage: SessionUsage? = nil, draft: String? = nil) {
        self.draft = draft
        self.id = id
        self.accountId = accountId
        self.provider = provider
        self.title = title
        self.cwd = cwd
        self.createdAt = createdAt
        self.lastActivity = lastActivity
        self.state = state
        self.stateDetail = stateDetail
        self.attention = attention
        self.hasWindow = hasWindow
        self.transcriptAvailable = transcriptAvailable
        self.model = model
        self.permissionMode = permissionMode
        self.gitBranch = gitBranch
        self.runningTasks = runningTasks
        self.lastMessage = lastMessage
        self.agentSessionId = agentSessionId
        self.columns = columns
        self.rows = rows
        self.usage = usage
    }
}

/// A choice the agent is waiting on, read from its terminal: a permission prompt, a trust dialog, a question.
nonisolated public struct AttentionPrompt: Codable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable {
        /// A numbered list with a cursor (❯ / ›): answering moves the cursor and presses Return.
        case choice
        /// A "(y/n)" question: answering types the letter and presses Return.
        case yesNo
    }

    /// Identifies this exact prompt, so an answer is only sent while the same prompt is still on screen.
    public var signature: String
    public var kind: Kind
    public var question: String
    /// The lines above the question, such as the command or the file the agent wants to change.
    public var context: String?
    public var options: [AttentionOption]
    public var selectedIndex: Int
    /// Footer hints the agent shows, such as "Esc to cancel · Tab to amend".
    public var hint: String?
    /// A checklist: Space ticks options, then an action ("Enable selected", "Submit") or Enter confirms.
    public var multiSelect: Bool?
    /// The keys the hint names, as buttons ("Space to select" → select, "Esc to reject all" → reject all).
    public var keyActions: [KeyAction]?
    /// The options sit side by side (a slider such as Claude Code's effort): ◀ ▶ move between them.
    public var horizontal: Bool?
    /// Nothing waits on it (a survey the agent shows after a turn): shown, but the session isn't "needs you".
    public var optional: Bool?
    /// Lines under the options that aren't keys: "… +3 models" (▼ scrolls to them), "◐ Medium effort (default)".
    public var footer: String?

    public init(signature: String, kind: Kind, question: String, context: String?, options: [AttentionOption],
                selectedIndex: Int, hint: String?, multiSelect: Bool? = nil, keyActions: [KeyAction]? = nil,
                horizontal: Bool? = nil, optional: Bool? = nil, footer: String? = nil) {
        self.signature = signature
        self.kind = kind
        self.question = question
        self.context = context
        self.options = options
        self.selectedIndex = selectedIndex
        self.hint = hint
        self.multiSelect = multiSelect
        self.keyActions = keyActions
        self.horizontal = horizontal
        self.optional = optional
        self.footer = footer
    }
}

/// A key a dialog says what it does with ("Esc to reject all").
nonisolated public struct KeyAction: Codable, Sendable, Hashable, Identifiable {
    public var id: String { label + keys.joined() }
    /// tmux key names: "Escape", "Enter", "Space", "Tab", "BTab", "C-e".
    public var keys: [String]
    /// What the dialog says the key does, capitalised ("Reject all").
    public var label: String
    /// How the key is written on a Mac keyboard ("esc", "space", "⌃E").
    public var keyName: String

    public init(keys: [String], label: String, keyName: String) {
        self.keys = keys
        self.label = label
        self.keyName = keyName
    }
}

nonisolated public struct AttentionOption: Codable, Sendable, Hashable, Identifiable {
    public var id: Int { index }
    public var index: Int
    public var label: String
    public var detail: String?
    /// Keys typed for a yes/no prompt (for a choice the cursor is moved instead).
    public var keys: [String]?
    /// In a checklist: whether this option is ticked (nil for a plain choice or an action).
    public var checked: Bool?
    /// An action line of a checklist ("Enable selected"), confirmed with Return.
    public var isAction: Bool?
    /// The choice that takes your own words ("Type something."): what you type goes there, then Return.
    public var takesText: Bool?
    /// Marked as the current one in the agent's list (✔), e.g. the model in use.
    public var isCurrent: Bool?

    public init(index: Int, label: String, detail: String? = nil, keys: [String]? = nil, checked: Bool? = nil,
                isAction: Bool? = nil, takesText: Bool? = nil, isCurrent: Bool? = nil) {
        self.index = index
        self.label = label
        self.detail = detail
        self.keys = keys
        self.checked = checked
        self.isAction = isAction
        self.takesText = takesText
        self.isCurrent = isCurrent
    }

    public var isToggle: Bool { checked != nil }

    /// Whether this option declines (shown as the destructive or cancel action).
    public var isNegative: Bool {
        let lower = label.lowercased()
        return lower.hasPrefix("no") || lower.contains("don't allow") || lower.contains("deny")
            || lower.contains("reject") || lower.hasPrefix("cancel") || lower.contains("exit")
    }
}

/// Something running in the background of a session: a shell, a subagent, a monitor, a workflow.
nonisolated public struct BackgroundTask: Codable, Sendable, Identifiable, Hashable {
    public enum Kind: String, Codable, Sendable {
        case shell, agent, monitor, workflow, fork, other
    }

    public enum Status: String, Codable, Sendable {
        case running, completed, failed, stopped
    }

    public var id: String
    public var kind: Kind
    public var title: String
    public var detail: String?
    public var status: Status
    /// A file whose growing contents are the task's output (shells and monitors).
    public var outputFile: String?
    /// The subagent whose own conversation can be opened.
    public var agentId: String?
    public var toolUseId: String?
    public var startedAt: Date?
    public var summary: String?

    public init(id: String, kind: Kind, title: String, detail: String? = nil, status: Status, outputFile: String? = nil,
                agentId: String? = nil, toolUseId: String? = nil, startedAt: Date? = nil, summary: String? = nil) {
        self.id = id
        self.kind = kind
        self.title = title
        self.detail = detail
        self.status = status
        self.outputFile = outputFile
        self.agentId = agentId
        self.toolUseId = toolUseId
        self.startedAt = startedAt
        self.summary = summary
    }
}

/// A past conversation of an account, which can be read or resumed in a new terminal.
nonisolated public struct HistoryEntry: Codable, Sendable, Identifiable, Hashable {
    public var id: String
    public var accountId: String
    public var title: String
    public var cwd: String?
    public var updatedAt: Date?
    public var sizeBytes: Int64?
    /// The settings the conversation last ran with, read from its own file, so it continues the same way.
    public var mode: String?
    public var model: String?
    public var effort: String?
    /// Those settings in words ("auto · claude-opus-5-5 · max effort").
    public var settings: String?
    /// Open in another terminal, as far as the hub can tell (for agents it can't ask, written to in the last two
    /// minutes).
    public var activeElsewhere: Bool?
    /// Open right now outside Agent Hub, as the agent itself reports (Claude Code): it can be taken over.
    public var running: RunningElsewhere?

    public init(id: String, accountId: String, title: String, cwd: String?, updatedAt: Date?, sizeBytes: Int64?,
                mode: String? = nil, model: String? = nil, effort: String? = nil, settings: String? = nil,
                activeElsewhere: Bool? = nil, running: RunningElsewhere? = nil) {
        self.running = running
        self.id = id
        self.accountId = accountId
        self.title = title
        self.cwd = cwd
        self.updatedAt = updatedAt
        self.sizeBytes = sizeBytes
        self.mode = mode
        self.model = model
        self.effort = effort
        self.settings = settings
        self.activeElsewhere = activeElsewhere
    }
}

/// A conversation open right now outside Agent Hub, as Claude Code itself lists it (`claude agents`).
nonisolated public struct RunningElsewhere: Codable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable {
        /// An interactive session in a terminal tab.
        case terminal
        /// A session in Claude Code's background service (`claude --bg`, its agent view).
        case background
    }

    public var kind: Kind
    /// Working on a turn right now: a terminal session is taken over when it finishes.
    public var busy: Bool
    /// A permission prompt or question there waits for an answer (Claude Code's own words, such as "input needed").
    /// It can't be answered from here; taking over closes it.
    public var waitingFor: String?
    /// The app showing it, such as "Terminal" or "iTerm2" (a terminal session).
    public var app: String?
    /// The agent's own name for the session ("pebble-26").
    public var name: String?

    public init(kind: Kind, busy: Bool, waitingFor: String? = nil, app: String? = nil, name: String? = nil) {
        self.kind = kind
        self.busy = busy
        self.waitingFor = waitingFor
        self.app = app
        self.name = name
    }
}
