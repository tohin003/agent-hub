import Foundation

/// An ordered timeline with a version per item, so the hub can send only what changed: to subscribed phones as
/// events, and to subagent views that poll with the last version they saw.
final class TimelineBuffer {
    private(set) var items: [TimelineItem] = []
    private var index: [String: Int] = [:]
    private var versions: [String: Int] = [:]
    private(set) var version = 0
    private var changedOrder: [String] = []
    private var changedSet: Set<String> = []

    var isEmpty: Bool { items.isEmpty }

    func item(_ id: String) -> TimelineItem? {
        index[id].map { items[$0] }
    }

    func contains(_ id: String) -> Bool { index[id] != nil }

    func upsert(_ item: TimelineItem) {
        if let position = index[item.id] {
            guard items[position] != item else { return }
            items[position] = item
        } else {
            index[item.id] = items.count
            items.append(item)
        }
        touch(item.id)
    }

    func update(_ id: String, _ change: (inout TimelineItem) -> Void) {
        guard let position = index[id] else { return }
        var copy = items[position]
        change(&copy)
        guard copy != items[position] else { return }
        items[position] = copy
        touch(id)
    }

    private func touch(_ id: String) {
        version += 1
        versions[id] = version
        if changedSet.insert(id).inserted { changedOrder.append(id) }
    }

    /// Items changed since the last drain, in timeline order.
    func drainChanges() -> [TimelineItem] {
        guard !changedOrder.isEmpty else { return [] }
        let ids = changedOrder.compactMap { index[$0] }.sorted()
        changedOrder.removeAll()
        changedSet.removeAll()
        return ids.map { items[$0] }
    }

    func changes(since: Int) -> [TimelineItem] {
        guard since > 0 else { return items }
        return items.filter { (versions[$0.id] ?? 0) > since }
    }

    func tail(_ count: Int) -> (items: [TimelineItem], hasEarlier: Bool) {
        let start = max(0, items.count - count)
        return (Array(items[start...]), start > 0)
    }

    func page(before id: String, limit: Int) -> (items: [TimelineItem], hasEarlier: Bool) {
        guard let end = index[id] else { return ([], false) }
        let start = max(0, end - limit)
        return (Array(items[start..<end]), start > 0)
    }

    /// Set when the timeline was cleared (the file was replaced); the next drain tells phones to start over.
    var resetPending = false

    func reset() {
        items.removeAll()
        index.removeAll()
        versions.removeAll()
        changedOrder.removeAll()
        changedSet.removeAll()
        version += 1
        resetPending = true
    }
}

/// What a transcript reader knows about the conversation besides its timeline.
struct TranscriptInfo: Equatable {
    var title: String?
    var model: String?
    var permissionMode: String?
    var lastMessage: String?
    var gitBranch: String?
    var agentSessionId: String?
    var lastActivity: Date?
    /// Context and plan limits, when the conversation file records them (Claude: tokens; Codex: tokens and limits).
    var usage: SessionUsage?
    /// The reasoning effort of the last turn, when recorded.
    var effort: String?
}

/// Reads one agent conversation incrementally.
protocol TranscriptReader: AnyObject {
    var buffer: TimelineBuffer { get }
    var info: TranscriptInfo { get }
    var tasks: [BackgroundTask] { get }
    /// Reads anything new. Returns true when the timeline, info or tasks changed.
    func poll() -> Bool
    /// The tool call with its untruncated input and output.
    func fullTool(_ id: String) -> ToolCall?
    /// A subagent's own conversation reader, when the agent keeps one.
    func subagentReader(_ agentId: String) -> TranscriptReader?
    var subagentFinished: Bool { get }
}

extension TranscriptReader {
    func subagentReader(_ agentId: String) -> TranscriptReader? { nil }
    var subagentFinished: Bool { false }
}

/// Shortening long text for the list; the full text stays available through `session.tool`.
enum Clip {
    static let outputLimit = 6_000
    static let inputLimit = 3_000

    static func text(_ value: String, limit: Int) -> (String, Bool) {
        guard value.count > limit else { return (value, false) }
        let head = value.prefix(limit * 2 / 3)
        let tail = value.suffix(limit / 3)
        let skipped = value.count - head.count - tail.count
        return ("\(head)\n… \(skipped) characters not shown …\n\(tail)", true)
    }

    static func oneLine(_ value: String, limit: Int = 160) -> String {
        let line = value.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? value
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.count > limit ? String(trimmed.prefix(limit - 1)) + "…" : trimmed
    }
}

/// Time stamps in the transcripts: ISO 8601 with or without fractional seconds.
enum Stamp {
    private static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let plain: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func parse(_ value: Any?) -> Date? {
        if let text = value as? String {
            return fractional.date(from: text) ?? plain.date(from: text)
        }
        if let number = value as? Double {
            return Date(timeIntervalSince1970: number > 1e12 ? number / 1000 : number)
        }
        if let number = value as? Int {
            return Date(timeIntervalSince1970: number > 1_000_000_000_000 ? Double(number) / 1000 : Double(number))
        }
        return nil
    }
}

/// Reads a growing JSONL file from where it left off, keeping a partial last line for the next read.
final class JSONLTail {
    let url: URL
    private(set) var offset: UInt64 = 0
    private var remainder = Data()
    private var inode: UInt64?

    init(url: URL) {
        self.url = url
    }

    enum Result {
        case none
        case lines([[String: Any]])
        /// The file was replaced or truncated: read again from the start.
        case reset
    }

    func read(maxBytes: Int = 64 * 1024 * 1024) -> Result {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attributes[.size] as? NSNumber)?.uint64Value else { return .none }
        let fileInode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
        if let inode, let fileInode, inode != fileInode {
            self.inode = fileInode
            offset = 0
            remainder = Data()
            return .reset
        }
        inode = fileInode
        if size < offset {
            offset = 0
            remainder = Data()
            return .reset
        }
        guard size > offset, let handle = try? FileHandle(forReadingFrom: url) else { return .none }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: offset)
            let length = Int(min(UInt64(maxBytes), size - offset))
            guard let chunk = try handle.read(upToCount: length), !chunk.isEmpty else { return .none }
            offset += UInt64(chunk.count)
            var data = remainder
            data.append(chunk)
            var lines: [[String: Any]] = []
            var start = data.startIndex
            while let newline = data[start...].firstIndex(of: 0x0A) {
                let lineData = data[start..<newline]
                if !lineData.isEmpty, let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] {
                    lines.append(object)
                }
                start = data.index(after: newline)
            }
            remainder = Data(data[start...])
            return lines.isEmpty ? .none : .lines(lines)
        } catch {
            return .none
        }
    }
}
