import Foundation

/// One entry in a session's chat timeline, normalised from Claude Code, Codex or OpenCode transcripts.
nonisolated public struct TimelineItem: Codable, Sendable, Identifiable, Hashable {
    public enum Kind: String, Codable, Sendable {
        /// Something you sent.
        case user
        /// The agent's reply text (Markdown).
        case assistant
        /// The agent's visible reasoning.
        case thinking
        /// A tool call with its result.
        case tool
        /// A note from the agent's harness: compaction, turn length, errors.
        case system
        /// A background task finished (task notifications).
        case task
        /// A slash command you ran and its output.
        case command
    }

    public var id: String
    public var kind: Kind
    public var timestamp: Date?
    public var text: String?
    public var tool: ToolCall?
    /// Severity for system items: "info", "notice", "warning", "error".
    public var level: String?
    /// Images attached to a user message, by file name only.
    public var attachments: [String]?

    public init(id: String, kind: Kind, timestamp: Date? = nil, text: String? = nil, tool: ToolCall? = nil,
                level: String? = nil, attachments: [String]? = nil) {
        self.id = id
        self.kind = kind
        self.timestamp = timestamp
        self.text = text
        self.tool = tool
        self.level = level
        self.attachments = attachments
    }
}

/// A tool call and what came back.
nonisolated public struct ToolCall: Codable, Sendable, Hashable {
    public enum Status: String, Codable, Sendable {
        /// Requested; no result yet (it may be waiting for your approval).
        case pending
        /// Running in the background; its output can be followed.
        case background
        case done
        case failed
        /// You (or a rule) declined it.
        case denied
    }

    public enum Category: String, Codable, Sendable {
        case shell, read, edit, write, search, web, agent, todo, question, plan, monitor, workflow, message, task,
             mcp, skill, notebook, other
    }

    public var id: String
    public var name: String
    public var category: Category
    /// A short line saying what the call does: the description the agent gave, or a summary of the input.
    public var title: String
    /// The exact command, path, pattern or URL.
    public var subtitle: String?
    /// The input as pretty JSON, truncated for the list (`session.tool` returns it in full).
    public var input: String?
    public var output: String?
    public var outputTruncated: Bool
    public var status: Status
    public var diff: FileDiff?
    public var todos: [TodoItem]?
    /// For subagents: the id whose own conversation `session.subagent` returns.
    public var agentId: String?
    public var agentType: String?
    /// For background shells and monitors: the task id and its output file.
    public var taskId: String?
    public var outputFile: String?
    public var questions: [QuestionSpec]?
    public var plan: String?
    public var durationMs: Int?
    public var exitCode: Int?

    public init(id: String, name: String, category: Category, title: String, subtitle: String? = nil,
                input: String? = nil, output: String? = nil, outputTruncated: Bool = false, status: Status,
                diff: FileDiff? = nil, todos: [TodoItem]? = nil, agentId: String? = nil, agentType: String? = nil,
                taskId: String? = nil, outputFile: String? = nil, questions: [QuestionSpec]? = nil,
                plan: String? = nil, durationMs: Int? = nil, exitCode: Int? = nil) {
        self.id = id
        self.name = name
        self.category = category
        self.title = title
        self.subtitle = subtitle
        self.input = input
        self.output = output
        self.outputTruncated = outputTruncated
        self.status = status
        self.diff = diff
        self.todos = todos
        self.agentId = agentId
        self.agentType = agentType
        self.taskId = taskId
        self.outputFile = outputFile
        self.questions = questions
        self.plan = plan
        self.durationMs = durationMs
        self.exitCode = exitCode
    }
}

/// A file change as unified-diff lines.
nonisolated public struct FileDiff: Codable, Sendable, Hashable {
    public var path: String
    public var lines: [DiffLine]
    public var additions: Int
    public var deletions: Int
    /// True for a new file written whole.
    public var isNewFile: Bool

    public init(path: String, lines: [DiffLine], additions: Int, deletions: Int, isNewFile: Bool) {
        self.path = path
        self.lines = lines
        self.additions = additions
        self.deletions = deletions
        self.isNewFile = isNewFile
    }
}

nonisolated public struct DiffLine: Codable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable {
        case context, add, remove, hunk
    }

    public var kind: Kind
    public var text: String

    public init(kind: Kind, text: String) {
        self.kind = kind
        self.text = text
    }
}

nonisolated public struct TodoItem: Codable, Sendable, Hashable {
    public enum Status: String, Codable, Sendable {
        case pending, inProgress, completed
    }

    public var content: String
    public var status: Status

    public init(content: String, status: Status) {
        self.content = content
        self.status = status
    }
}

/// A question the agent asked with choices (Claude's AskUserQuestion).
nonisolated public struct QuestionSpec: Codable, Sendable, Hashable {
    public var question: String
    public var header: String?
    public var options: [QuestionOption]
    public var multiSelect: Bool

    public init(question: String, header: String?, options: [QuestionOption], multiSelect: Bool) {
        self.question = question
        self.header = header
        self.options = options
        self.multiSelect = multiSelect
    }
}

nonisolated public struct QuestionOption: Codable, Sendable, Hashable {
    public var label: String
    public var description: String?

    public init(label: String, description: String?) {
        self.label = label
        self.description = description
    }
}
