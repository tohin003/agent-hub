import Foundation
import Testing

/// The hub's Space switch: it answers once the Mac is there, however long that takes, and moves only as far as asked.
/// On a fake Mac: no real Space is ever switched.
@Suite("Space switch")
struct SpaceSwitcherTests {
    /// A display with a desktop and two full-screen apps, whose current Space changes `delay` after the keys are pressed
    /// (never, when nil).
    final class FakeMac: SpacesBackend, @unchecked Sendable {
        private let lock = NSLock()
        private var current: Int
        private(set) var moves: [Int] = []
        let delay: Duration?

        init(current: Int = 0, delay: Duration?) {
            self.current = current
            self.delay = delay
        }

        func displays() async -> [DisplayInfo] {
            let current = lock.withLock { self.current }
            let spaces = [UInt64(3), 41, 57].enumerated().map { index, id in
                SpaceInfo(id: id, index: index, isFullscreen: index > 0, isCurrent: index == current, title: nil)
            }
            return [DisplayInfo(id: 1, name: "Built-in Display", width: 1470, height: 956, isMain: true, spaces: spaces)]
        }

        func move(display: UInt32, steps: Int) async {
            lock.withLock { moves.append(steps) }
            guard let delay else { return }
            Task {
                try? await Task.sleep(for: delay)
                self.lock.withLock { self.current = max(0, min(2, self.current + steps)) }
            }
        }
    }

    @Test func itAnswersOnceTheMacIsThere() async {
        let mac = FakeMac(delay: .milliseconds(600))
        let outcome = await SpaceSwitcher(backend: mac).switchTo(display: 1, index: 1, steps: nil)
        let ms = outcome.took / .milliseconds(1)
        print("space switch: answered \(Int(ms)) ms after the press, the Mac taking 600")
        #expect(outcome.reached)
        #expect(ms >= 600 && ms < 700, "not before the Mac is there, and soon after: \(ms) ms")
        #expect(outcome.displays.first?.currentSpaceIndex == 1)
        #expect(mac.moves == [1])
    }

    @Test func aMacThatNeverGetsThereTimesOut() async {
        let mac = FakeMac(delay: nil)
        var switcher = SpaceSwitcher(backend: mac)
        switcher.timeout = .milliseconds(300)
        let outcome = await switcher.switchTo(display: 1, index: 2, steps: nil)
        #expect(!outcome.reached)
        #expect(outcome.displays.first?.currentSpaceIndex == 0, "the answer says where the Mac really is")
        #expect(outcome.took >= .milliseconds(300))
    }

    @Test func itMovesOnlyAsFarAsAsked() async {
        // Two along from the desktop, by index.
        let byIndex = FakeMac(delay: .milliseconds(50))
        #expect(await SpaceSwitcher(backend: byIndex).switchTo(display: 1, index: 2, steps: nil).reached)
        #expect(byIndex.moves == [2])
        // A step past the last Space stops at the last.
        let pastTheEnd = FakeMac(current: 1, delay: .milliseconds(50))
        #expect(await SpaceSwitcher(backend: pastTheEnd).switchTo(display: 1, index: nil, steps: 5).reached)
        #expect(pastTheEnd.moves == [1])
        // Already there: nothing pressed, answered at once.
        let there = FakeMac(current: 1, delay: .milliseconds(50))
        let outcome = await SpaceSwitcher(backend: there).switchTo(display: 1, index: 1, steps: nil)
        #expect(outcome.reached && outcome.took == .zero && there.moves.isEmpty)
    }

    @Test func spaceChangesAreTheCurrentOnes() async {
        let before = await FakeMac(current: 0, delay: nil).displays()
        let after = await FakeMac(current: 2, delay: nil).displays()
        #expect(SpaceChanges.changed(before, after) == [1])
        #expect(SpaceChanges.changed(after, after).isEmpty)
        #expect(SpaceChanges.changed([], after) == [1], "nothing known before: tell")
    }
}
