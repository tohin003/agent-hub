import Foundation

/// What switching Spaces needs from the Mac: `SystemSpaces` on the real one, a fake in the tests.
protocol SpacesBackend: Sendable {
    func displays() async -> [DisplayInfo]
    /// Presses the switch `steps` Spaces along (negative: left) on `display`, returning after the last press.
    func move(display: UInt32, steps: Int) async
}

/// Switches a display to a Space and answers once the Mac has actually got there, as its own Spaces list says. The
/// answer used to go a fixed 670 ms after the key press (420 ms, then 250 more), whatever the Mac did: early when it
/// took longer, so the phone went back to the old page while the Mac went on, and late when it was quicker.
struct SpaceSwitcher: Sendable {
    let backend: any SpacesBackend
    /// The most it waits for the Mac to get there.
    var timeout: Duration = .seconds(2)
    var poll: Duration = .milliseconds(15)

    struct Outcome: Sendable {
        var displays: [DisplayInfo]
        /// The Mac reached the Space asked for (or was there already).
        var reached: Bool
        /// From the request to the Mac's list saying it's there (or giving up).
        var took: Duration
        var from: Int?
        var to: Int?
    }

    /// To the Space at `index` in the display's list, or `steps` along from its current one.
    func switchTo(display: UInt32, index: Int?, steps: Int?) async -> Outcome {
        let clock = ContinuousClock()
        let start = clock.now
        let before = await backend.displays()
        guard let info = before.first(where: { $0.id == display }), let from = info.currentSpaceIndex, !info.spaces.isEmpty
        else {
            // A Mac whose Spaces can't be read: only moving, as ever.
            if let steps, steps != 0 { await backend.move(display: display, steps: steps) }
            return Outcome(displays: await backend.displays(), reached: false, took: clock.now - start, from: nil, to: nil)
        }
        let target = min(max(index ?? from + (steps ?? 0), 0), info.spaces.count - 1)
        guard target != from else { return Outcome(displays: before, reached: true, took: .zero, from: from, to: target) }
        let goal = info.spaces[target].id
        await backend.move(display: display, steps: target - from)
        while true {
            let now = await backend.displays()
            let current = now.first { $0.id == display }?.spaces.first(where: \.isCurrent)?.id
            if current == goal || clock.now - start >= timeout {
                return Outcome(displays: now, reached: current == goal, took: clock.now - start, from: from, to: target)
            }
            try? await Task.sleep(for: poll)
        }
    }
}

/// Which displays' current Spaces differ between two lists: a change to tell the phones about.
enum SpaceChanges {
    static func changed(_ old: [DisplayInfo], _ new: [DisplayInfo]) -> [UInt32] {
        new.compactMap { display in
            let before = old.first { $0.id == display.id }
            return before?.spaces.first(where: \.isCurrent)?.id != display.spaces.first(where: \.isCurrent)?.id
                || before?.spaces.map(\.id) != display.spaces.map(\.id) ? display.id : nil
        }
    }
}
