import Foundation

/// The Screen tab's Spaces pager, apart from the view so it can be tested: which page it shows, when the Mac is asked to
/// switch, and when the page follows the Mac. Whoever switches (a swipe here, the Spaces bar, or someone at the Mac),
/// the page ends on the Mac's current Space; a swipe asks the Mac exactly once; a page shows the Mac live only once the
/// Mac has got there, so its snapshot covers the Mac's own slide (no second slide on the phone).
///
/// The view tells it what happened: the Spaces the Mac reports (`received`, `switched`), where the finger left the pager
/// (`settled`; never for a scroll the view made itself, so pages passed on the way don't count) and the Spaces bar
/// (`step`). It does what comes back.
nonisolated public struct SpaceFollower: Sendable, Equatable {
    public enum Action: Equatable, Sendable {
        case none
        /// Move the pager to this page by itself (not under the finger).
        case scroll(to: UInt64)
        /// Ask the Mac to switch to the Space at `index` in its list; the pager is on (or goes to) `page` meanwhile.
        case switchMac(index: Int, page: UInt64)
    }

    /// The display's Spaces as the Mac last reported them, with its current one.
    public private(set) var spaces: [SpaceInfo] = []
    /// The page the pager shows, or is on its way to.
    public private(set) var page: UInt64?
    /// The Space a switch asked of the Mac is going to; nil when none is on its way.
    public private(set) var switching: UInt64?
    /// Where the finger (or the bar) went while a switch was on its way: the next switch, once that one's answered.
    public private(set) var queued: UInt64?

    public init() {}

    /// The Mac's current Space.
    public var current: UInt64? { spaces.first(where: \.isCurrent)?.id }

    /// Whether a page shows the Mac live: its Space is current and no switch is on its way elsewhere.
    public func isLive(_ id: UInt64) -> Bool { id == current && (switching == nil || switching == id) && queued == nil }

    /// Whether a page asks to be swiped to: a Space the Mac isn't on and isn't going to.
    public func invitesSwitch(_ id: UInt64) -> Bool { id != current && id != switching && id != queued }

    /// Spaces from the Mac: a reload, or the Mac switching by itself. The page follows its current Space, unless a
    /// switch the phone asked for is on its way (its answer settles the page).
    public mutating func received(_ list: [SpaceInfo]) -> Action {
        spaces = list
        guard switching == nil, let current else { return .none }
        guard page != current else { return .none }
        page = current
        return .scroll(to: current)
    }

    /// The finger left the pager on `page`.
    public mutating func settled(on page: UInt64) -> Action {
        self.page = page
        return go(to: page)
    }

    /// The Spaces bar: the Space before (-1) or after (1) the one shown, or on its way.
    public mutating func step(_ direction: Int) -> Action {
        guard !spaces.isEmpty else { return .none }
        let from = queued ?? switching ?? page ?? current
        guard let index = spaces.firstIndex(where: { $0.id == from }) ?? spaces.firstIndex(where: \.isCurrent) else { return .none }
        let target = spaces[min(max(index + direction, 0), spaces.count - 1)].id
        guard target != from else { return .none }
        page = target
        switch go(to: target) {
        case .none: return .scroll(to: target)
        case let action: return action
        }
    }

    /// The Mac's answer to a switch: its Spaces once it got there (nil: the switch failed). A swipe made meanwhile
    /// goes next; else the page ends where the Mac is.
    public mutating func switched(_ list: [SpaceInfo]?) -> Action {
        if let list { spaces = list }
        switching = nil
        if let next = queued {
            queued = nil
            if next != current, let space = spaces.first(where: { $0.id == next }) {
                switching = next
                page = next
                return .switchMac(index: space.index, page: next)
            }
        }
        guard let current, page != current else { return .none }
        page = current
        return .scroll(to: current)
    }

    /// Asks the Mac for `target` unless it's there or on its way; one switch at a time.
    private mutating func go(to target: UInt64) -> Action {
        if let switching {
            queued = target == switching ? nil : target
            return .none
        }
        guard target != current, let space = spaces.first(where: { $0.id == target }) else { return .none }
        switching = target
        return .switchMac(index: space.index, page: target)
    }
}
