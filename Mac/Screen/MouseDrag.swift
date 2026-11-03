import CoreGraphics
import Foundation

/// What a live drag needs from the Mac: `SystemMousePoster` on the real one, a fake in the tests.
protocol MouseEventPoster {
    /// The button down at `point` (global display points), with click state 1: a press, never a double-click, so a file
    /// picked up in Finder isn't opened.
    func down(at point: CGPoint)
    func dragged(to point: CGPoint)
    func up(at point: CGPoint)
}

/// A live drag from a phone (double-tap and drag, or double-tap and hold to pick up): the button goes down where the
/// drag starts, the pointer follows each move, and the button comes up where it ends. Whatever happens on the way, the
/// button never stays down: it comes up when that phone goes, when another drag or any other input comes, or after
/// `idleLimit` with no move. Each drag is logged when it starts and when it ends, with what ended it, so a try on the
/// phone can be read back from the hub's log.
@MainActor
final class MouseDragSession {
    /// A drag with no move for this long is over: the phone went quiet (lost, asleep, or its end got lost). A phone holding
    /// a finger still says so every second.
    nonisolated static let idleLimit: Duration = .seconds(4)

    /// A drag picked up by a hold presses the button only once the finger has moved this far (points) from where the
    /// drag started, and then drags at once. Finder doesn't lift a file whose press sat still before the drag: on the
    /// person's Mac (2026-11-03), a press that waited 840 ms for the finger to move dragged only the pointer, while a
    /// press dragged 11 ms later moved the folder.
    nonisolated static let pressDistance: CGFloat = 12

    /// What ended a drag, for the log.
    enum Ending: Sendable {
        case lift, timeout, phoneLeft, anotherDrag, otherInput
    }

    private let poster: MouseEventPoster
    private let idleLimit: Duration
    private let log: (String) -> Void
    /// Whose drag it is, and where the pointer is.
    private(set) var owner: UUID?
    private(set) var position = CGPoint.zero
    /// Where the drag started (the button goes down there), and whether it's down yet.
    private var origin = CGPoint.zero
    private(set) var pressed = false
    private var watchdog: Task<Void, Never>?
    /// The drag under way, for its log lines: when it started, its moves and how far they took the pointer (points).
    private var started = ContinuousClock.now
    private var moves = 0
    private var travelled = 0.0

    init(poster: MouseEventPoster, idleLimit: Duration = MouseDragSession.idleLimit,
         log: @escaping (String) -> Void = { Log.info($0) }) {
        self.poster = poster
        self.idleLimit = idleLimit
        self.log = log
    }

    var isDragging: Bool { owner != nil }

    /// `how`: how the phone started it ("picked up by a hold", "moving"), for the log. `pressOnMove` (a pick-up): the
    /// button goes down only once the finger moves `pressDistance`, right before the drag's first step.
    func start(at point: CGPoint, by client: UUID, how: String = "moving", pressOnMove: Bool = false) {
        if owner != nil { finish(.anotherDrag) }
        owner = client
        origin = point
        position = point
        pressed = false
        started = .now
        moves = 0
        travelled = 0
        log("drag: started (\(how)) at \(Int(point.x)),\(Int(point.y))")
        if !pressOnMove { press() }
        arm()
    }

    /// A move to where the pointer already is posts nothing: it's the phone saying the finger is still down, held still
    /// (it says so every second), and only keeps the drag going.
    func move(to point: CGPoint, by client: UUID) {
        guard owner == client else { return }
        follow(to: point)
        arm()
    }

    func end(at point: CGPoint?, by client: UUID) {
        guard owner == client else { return }
        // The finger lifted where the last move hadn't reached yet: the pointer goes there first, as a mouse's would.
        if let point { follow(to: point) }
        finish(.lift)
    }

    /// The pointer follows the finger. A pick-up's button isn't down yet: it goes down where the drag started once the
    /// finger is `pressDistance` away, and the first step follows at once. Until then the pointer stays put.
    private func follow(to point: CGPoint) {
        if !pressed {
            guard hypot(point.x - origin.x, point.y - origin.y) >= Self.pressDistance else { return }
            press()
        }
        if point != position { step(to: point) }
    }

    private func press() {
        pressed = true
        poster.down(at: origin)
    }

    /// A phone went: its drag ends where the pointer is.
    func clientLeft(_ client: UUID) {
        guard owner == client else { return }
        finish(.phoneLeft)
    }

    /// Any other input (a click, a key, a scroll) while a drag is under way: that drag's end got lost, so it ends first,
    /// where the pointer is.
    func interrupt() {
        guard owner != nil else { return }
        finish(.otherInput)
    }

    private func step(to point: CGPoint) {
        travelled += hypot(point.x - position.x, point.y - position.y)
        moves += 1
        position = point
        poster.dragged(to: point)
    }

    private func finish(_ ending: Ending) {
        watchdog?.cancel()
        watchdog = nil
        owner = nil
        // A pick-up the finger never moved far enough never pressed: nothing to let go.
        if pressed { poster.up(at: position) }
        log(String(format: "drag: ended by %@ after %.1f s, %ld moves, %.0f pt%@", describe(ending),
                   Self.seconds(.now - started), moves, travelled, pressed ? "" : " (never pressed)"))
        pressed = false
    }

    private func describe(_ ending: Ending) -> String {
        switch ending {
        case .lift: "the lift"
        case .timeout: String(format: "the timeout (no word from the phone for %g s)", Self.seconds(idleLimit))
        case .phoneLeft: "the phone leaving"
        case .anotherDrag: "another drag"
        case .otherInput: "other input"
        }
    }

    private static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    private func arm() {
        watchdog?.cancel()
        let limit = idleLimit
        watchdog = Task { [weak self] in
            try? await Task.sleep(for: limit)
            guard !Task.isCancelled, let self, self.owner != nil else { return }
            self.finish(.timeout)
        }
    }
}
