import CoreGraphics
import Foundation
import Testing

/// The privacy screen's hold on the displays' output, on fake displays and a fake Mac: no real display is ever blacked
/// out or faded, and no real Space is switched.
@Suite("Privacy screen: the displays' output")
struct DisplayBlackoutTests {
    /// What happened, in order: the fake displays, the fake fade and the fake Mac all write here.
    final class Journal: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []
        func add(_ line: String) { lock.withLock { lines.append(line) } }
        var all: [String] { lock.withLock { lines } }
        func index(of line: String) -> Int? { all.firstIndex(of: line) }
        func contains(_ prefix: String) -> Bool { all.contains { $0.hasPrefix(prefix) } }
    }

    /// Displays with transfer tables: `noTable` ones have none (AirPlay), `ignoring` ones take nothing.
    final class FakeDisplays: DisplayOutput, @unchecked Sendable {
        let journal: Journal
        var online: [CGDirectDisplayID]
        var tables: [CGDirectDisplayID: TransferTable]
        var noTable: Set<CGDirectDisplayID> = []
        var ignoring: Set<CGDirectDisplayID> = []
        private(set) var profileRestores = 0

        init(journal: Journal, tables: [CGDirectDisplayID: TransferTable]) {
            self.journal = journal
            self.tables = tables
            online = tables.keys.sorted()
        }

        func displays() -> [CGDirectDisplayID] { online }

        func table(of display: CGDirectDisplayID) -> TransferTable? {
            guard online.contains(display), !noTable.contains(display) else { return nil }
            return tables[display]
        }

        func setTable(_ table: TransferTable, on display: CGDirectDisplayID) -> Bool {
            guard online.contains(display), !noTable.contains(display) else { return false }
            journal.add("display \(display) \(table.isBlack ? "black" : "back")")
            if !ignoring.contains(display) { tables[display] = table }
            return true
        }

        func restoreProfiles() {
            profileRestores += 1
            journal.add("profiles")
        }
    }

    final class FakeFader: DisplayFader, @unchecked Sendable {
        let journal: Journal
        var refuses = false
        init(journal: Journal) { self.journal = journal }
        func black(for limit: Duration) -> Bool {
            guard !refuses else { return false }
            journal.add("fade black")
            return true
        }
        func back() { journal.add("fade back") }
    }

    /// A display with a desktop and two full-screen apps whose Space changes `delay` after the shortcut (never, nil).
    final class FakeMac: SpacesBackend, @unchecked Sendable {
        let journal: Journal
        private let lock = NSLock()
        private var current = 0
        private var arrived = false
        let delay: Duration?

        init(journal: Journal, delay: Duration?) {
            self.journal = journal
            self.delay = delay
        }

        func displays() async -> [DisplayInfo] {
            let (current, first) = lock.withLock { () -> (Int, Bool) in
                let first = !arrived && self.current != 0
                if first { arrived = true }
                return (self.current, first)
            }
            if first { journal.add("Mac there") }
            let spaces = [UInt64(3), 41, 57].enumerated().map { index, id in
                SpaceInfo(id: id, index: index, isFullscreen: index > 0, isCurrent: index == current, title: nil)
            }
            return [DisplayInfo(id: 1, name: "Built-in Display", width: 1470, height: 956, isMain: true, spaces: spaces)]
        }

        func move(display: UInt32, steps: Int) async {
            journal.add("key press")
            guard let delay else { return }
            Task {
                try? await Task.sleep(for: delay)
                self.lock.withLock { self.current = max(0, min(2, self.current + steps)) }
            }
        }
    }

    /// An ordinary table, and a warm one (Night Shift lowers blue).
    static let plain = TransferTable(red: (0..<8).map { Float($0) / 7 }, green: (0..<8).map { Float($0) / 7 },
                                     blue: (0..<8).map { Float($0) / 7 })
    static let warm = TransferTable(red: plain.red, green: plain.green.map { $0 * 0.9 }, blue: plain.blue.map { $0 * 0.6 })
    static let warmer = TransferTable(red: plain.red, green: plain.green.map { $0 * 0.85 }, blue: plain.blue.map { $0 * 0.4 })

    let start = ContinuousClock.now
    func at(_ milliseconds: Int) -> ContinuousClock.Instant { start + .milliseconds(milliseconds) }

    func marker() -> String {
        FileManager.default.temporaryDirectory.appendingPathComponent("blackout-\(UUID().uuidString).json").path
    }

    func setUp(marker: String? = nil) -> (Journal, FakeDisplays, FakeFader, PrivacyShade) {
        let journal = Journal()
        let displays = FakeDisplays(journal: journal, tables: [1: Self.plain, 2: Self.warm])
        let fader = FakeFader(journal: journal)
        return (journal, displays, fader, PrivacyShade(output: displays, fader: fader, markerPath: marker))
    }

    @Test func withTheCurtainDownNothingIsEverBlackedOut() async {
        let (journal, displays, _, shade) = setUp()
        shade.tick(at: at(0))
        #expect(shade.switchBegins() == false)
        shade.switchEnded(at: at(10))
        shade.unlockingBegan()
        shade.unlockingEnded(at: at(20))
        let switched = await shade.shadedSwitch(SpaceSwitcher(backend: FakeMac(journal: journal, delay: .milliseconds(50))),
                                                display: 1, index: 1, steps: nil, curtainShown: { true })
        #expect(switched.ended == nil)
        #expect(journal.all == ["key press", "Mac there"], "\(journal.all)")
        #expect(displays.tables == [1: Self.plain, 2: Self.warm])
        #expect(DisplayBlackout.recover(output: displays, markerPath: marker()) == nil)
    }

    @Test func upEveryDisplayGoesBlackAndDownEachGetsItsOwnTableBack() {
        let path = marker()
        let (journal, displays, _, shade) = setUp(marker: path)
        shade.curtainUp(at: at(0))
        #expect(displays.tables[1]?.isBlack == true && displays.tables[2]?.isBlack == true)
        #expect(shade.blackout.blackDisplays == [1, 2])
        #expect(FileManager.default.fileExists(atPath: path), "the tables are written down while black")
        shade.curtainDown()
        #expect(displays.tables == [1: Self.plain, 2: Self.warm], "Night Shift's table comes back as it was")
        #expect(!FileManager.default.fileExists(atPath: path))
        #expect(journal.all == ["display 1 black", "display 2 black", "display 1 back", "display 2 back"], "\(journal.all)")
        #expect(displays.profileRestores == 0)
    }

    @Test func aDisplayWithoutATableOrThatTakesNoneIsLeftToTheWindow() {
        let (journal, displays, _, shade) = setUp()
        displays.online = [1, 2, 3]
        displays.tables[3] = Self.plain
        displays.noTable = [2]
        displays.ignoring = [3]
        shade.curtainUp(at: at(0))
        #expect(shade.blackout.blackDisplays == [1])
        #expect(shade.blackout.windowOnlyDisplays == [2, 3])
        #expect(displays.tables[2] == Self.warm && displays.tables[3] == Self.plain)
        shade.curtainDown()
        #expect(displays.tables == [1: Self.plain, 2: Self.warm, 3: Self.plain])
        #expect(!journal.all.contains("display 2 black"))
    }

    @Test func aTableSomethingElsePutsBackGoesBlackAgainAndTheNewestComesBack() {
        let (_, displays, _, shade) = setUp()
        shade.curtainUp(at: at(0))
        // Evening: Night Shift deepens (or a wake, or a profile change, puts a table back).
        displays.tables[2] = Self.warmer
        shade.tick(at: at(500))
        #expect(displays.tables[2]?.isBlack == true)
        shade.curtainDown()
        #expect(displays.tables[2] == Self.warmer, "the newest table it had comes back")
    }

    @Test func displaysComeAndGo() {
        let (journal, displays, _, shade) = setUp()
        displays.online = [1]
        shade.curtainUp(at: at(0))
        #expect(shade.blackout.blackDisplays == [1])
        displays.online = [1, 2]
        shade.tick(at: at(500))
        #expect(displays.tables[2]?.isBlack == true, "a display that comes goes black")
        displays.online = [2]
        shade.tick(at: at(1000))
        #expect(shade.blackout.blackDisplays == [2], "one that went is forgotten")
        shade.curtainDown()
        #expect(displays.tables[2] == Self.warm)
        #expect(journal.all.filter { $0.hasPrefix("display 1") } == ["display 1 black"], "nothing set on a display that went")
    }

    @Test func startingToUnlockGivesTheDisplaysBack() {
        let (_, displays, _, shade) = setUp()
        shade.curtainUp(at: at(0))
        shade.unlockingBegan()
        #expect(displays.tables == [1: Self.plain, 2: Self.warm], "whoever is at the Mac sees the unlock panel")
        shade.tick(at: at(500))
        #expect(displays.tables[1]?.isBlack == false, "and keeps seeing it while unlocking")
        shade.unlockingEnded(at: at(30_000))
        #expect(displays.tables[1]?.isBlack == true, "given up or idle: black again")
        shade.curtainDown()
        #expect(displays.tables == [1: Self.plain, 2: Self.warm])
    }

    @Test func theWatchdogGivesTheDisplaysBack() {
        let path = marker()
        let (_, displays, _, shade) = setUp(marker: path)
        shade.curtainUp(at: at(0))
        #expect(shade.blackout.watchdog(at: at(2_000)) == false, "a slow beat isn't a stuck hub")
        #expect(shade.blackout.watchdog(at: at(3_500)) == true)
        #expect(displays.tables == [1: Self.plain, 2: Self.warm])
        #expect(!FileManager.default.fileExists(atPath: path))
        // The main thread beats again: black again.
        shade.tick(at: at(4_000))
        #expect(displays.tables[1]?.isBlack == true)
        #expect(shade.blackout.watchdog(at: at(4_500)) == false)
        shade.curtainDown()
    }

    @Test func aHubThatCrashedGivesTheDisplaysBackWhenItStarts() {
        let path = marker()
        let (_, displays, _, shade) = setUp(marker: path)
        shade.curtainUp(at: at(0))
        _ = shade   // the hub crashed here: nothing given back
        #expect(displays.tables[1]?.isBlack == true)
        #expect(DisplayBlackout.recover(output: displays, markerPath: path) == 2)
        #expect(displays.tables == [1: Self.plain, 2: Self.warm])
        #expect(!FileManager.default.fileExists(atPath: path))
        #expect(DisplayBlackout.recover(output: displays, markerPath: path) == nil, "once")
        // macOS put a display back by itself meanwhile: left alone; a black one nobody wrote down: its profile.
        let again = setUp(marker: path)
        again.3.curtainUp(at: at(0))
        again.1.tables[1] = Self.plain
        again.1.online = [1, 2, 3]
        again.1.tables[3] = .black(count: 8)
        #expect(DisplayBlackout.recover(output: again.1, markerPath: path) == 2)
        #expect(again.1.tables[1] == Self.plain && again.1.tables[2] == Self.warm)
        #expect(again.1.profileRestores == 1)
    }

    // MARK: Around a switch the hub makes

    @Test @MainActor func aSwitchIsFadedFromBeforeTheKeyPressUntilTheCurtainShows() async {
        let (journal, displays, _, shade) = setUp()
        shade.curtainUp(at: .now)
        let mac = FakeMac(journal: journal, delay: .milliseconds(300))
        var shownAt: ContinuousClock.Instant?
        let switched = await shade.shadedSwitch(SpaceSwitcher(backend: mac), display: 1, index: 1, steps: nil,
                                                curtainShown: {
            if shownAt == nil { shownAt = .now + .milliseconds(100) }
            let shown = ContinuousClock.now >= shownAt!
            if shown, !journal.contains("curtain shown") { journal.add("curtain shown") }
            return shown
        })
        #expect(switched.outcome.reached)
        #expect(!journal.contains("fade back"), "the phone's answer doesn't wait for the displays")
        await switched.ended?.value
        let order = ["fade black", "key press", "Mac there", "curtain shown", "fade back"].map { journal.index(of: $0) }
        #expect(order.allSatisfy { $0 != nil } && order.map { $0 ?? -1 } == order.map { $0 ?? -1 }.sorted(), "\(journal.all)")
        #expect(displays.tables[1]?.isBlack == true, "and the tables are black again after the fade")
        shade.curtainDown()
    }

    @Test @MainActor func aSwitchThatNeverGetsThereStillGivesTheDisplaysBack() async {
        let (journal, _, _, shade) = setUp()
        shade.curtainUp(at: .now)
        var switcher = SpaceSwitcher(backend: FakeMac(journal: journal, delay: nil))
        switcher.timeout = .milliseconds(300)
        let switched = await shade.shadedSwitch(switcher, display: 1, index: 2, steps: nil, curtainShown: { true })
        #expect(!switched.outcome.reached)
        await switched.ended?.value
        #expect(journal.all.filter { $0.hasPrefix("fade") } == ["fade black", "fade back"])
        #expect(!journal.contains("Mac there"))
        shade.curtainDown()
    }

    @Test func switchesOnTopOfEachOtherKeepTheFadeUntilTheLast() {
        let (journal, _, _, shade) = setUp()
        shade.curtainUp(at: at(0))
        #expect(shade.switchBegins() && shade.switchBegins())
        shade.switchEnded(at: at(900))
        #expect(!journal.contains("fade back"))
        shade.switchEnded(at: at(1_400))
        #expect(journal.all.filter { $0.hasPrefix("fade") } == ["fade black", "fade back"])
        // Turning the curtain off in the middle of a switch gives everything back too.
        #expect(shade.switchBegins())
        shade.curtainDown()
        #expect(journal.all.filter { $0.hasPrefix("fade") } == ["fade black", "fade back", "fade black", "fade back"])
        shade.switchEnded(at: at(2_000))
        #expect(journal.all.filter { $0.hasPrefix("fade") }.count == 4)
    }

    @Test func aFadeMacOSRefusesIsNeverUndone() {
        let (journal, _, fader, shade) = setUp()
        fader.refuses = true
        shade.curtainUp(at: at(0))
        #expect(shade.switchBegins(), "still shaded: the tables keep it black")
        shade.switchEnded(at: at(900))
        #expect(!journal.contains("fade"))
        shade.curtainDown()
    }
}
