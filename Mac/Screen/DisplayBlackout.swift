import CoreGraphics
import Foundation

/// A display's transfer table (its gamma curve) as macOS keeps it: values from 0 to 1 along each channel.
struct TransferTable: Codable, Equatable, Sendable {
    var red: [Float]
    var green: [Float]
    var blue: [Float]

    var count: Int { red.count }

    /// Every step black: whatever the Mac draws, the display shows nothing.
    static func black(count: Int) -> TransferTable {
        let zeros = [Float](repeating: 0, count: max(count, 2))
        return TransferTable(red: zeros, green: zeros, blue: zeros)
    }

    var isBlack: Bool { red.allSatisfy { $0 <= 0.0001 } && green.allSatisfy { $0 <= 0.0001 } && blue.allSatisfy { $0 <= 0.0001 } }
}

/// The displays' output, which the privacy screen blacks out: the real Mac's (`SystemDisplayOutput`), or a fake in the
/// tests.
protocol DisplayOutput: AnyObject {
    func displays() -> [CGDirectDisplayID]
    /// The display's transfer table now; nil when it has none to set (AirPlay, Sidecar and the like).
    func table(of display: CGDirectDisplayID) -> TransferTable?
    /// False when the display refuses it.
    func setTable(_ table: TransferTable, on display: CGDirectDisplayID) -> Bool
    /// Every display back to its ColorSync profile's own table.
    func restoreProfiles()
}

/// A fade of every display to black and back, for a change the hub makes: the real Mac's (`SystemFader`), or a fake.
protocol DisplayFader: AnyObject {
    /// Every display black at once; false when macOS wouldn't. Whatever happens, the displays come back by themselves
    /// after `limit`.
    func black(for limit: Duration) -> Bool
    /// Back as they were.
    func back()
}

/// The real displays: Quartz Display Services' transfer tables, which "are loaded into display hardware" (the
/// header's words): the hardware applies them to what it shows, after macOS has drawn everything. Screen capture reads
/// what's drawn, before that (the phone's streams even leave the curtain's own windows out, so they can't be reading
/// the display's output): the phone's picture doesn't change.
final class SystemDisplayOutput: DisplayOutput {
    func displays() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return [] }
        return Array(ids.prefix(Int(count)))
    }

    func table(of display: CGDirectDisplayID) -> TransferTable? {
        let capacity = CGDisplayGammaTableCapacity(display)
        guard capacity > 1 else { return nil }
        var red = [CGGammaValue](repeating: 0, count: Int(capacity))
        var green = red
        var blue = red
        var samples: UInt32 = 0
        guard CGGetDisplayTransferByTable(display, capacity, &red, &green, &blue, &samples) == .success, samples > 1 else {
            return nil
        }
        let count = Int(samples)
        return TransferTable(red: Array(red.prefix(count)), green: Array(green.prefix(count)), blue: Array(blue.prefix(count)))
    }

    func setTable(_ table: TransferTable, on display: CGDirectDisplayID) -> Bool {
        CGSetDisplayTransferByTable(display, UInt32(table.count), table.red, table.green, table.blue) == .success
    }

    func restoreProfiles() {
        CGDisplayRestoreColorSyncSettings()
    }
}

/// The real fade: a fade reservation and `CGDisplayFade`, which "blends the video output with the specified color".
/// A reservation that isn't given back in time is undone by macOS ("the hardware being unfaded back to a normal
/// state"), so a hub that hangs mid-switch can't leave the Mac black.
final class SystemFader: DisplayFader {
    private var token: CGDisplayFadeReservationToken = 0

    func black(for limit: Duration) -> Bool {
        guard token == 0 else { return true }
        // At most 15 s (`kCGMaxDisplayReservationInterval`).
        let seconds = Float(min(max(Double(limit.components.seconds) + Double(limit.components.attoseconds) / 1e18, 0.5), 15))
        var reserved: CGDisplayFadeReservationToken = 0
        guard CGAcquireDisplayFadeReservation(seconds, &reserved) == .success else { return false }
        guard CGDisplayFade(reserved, 0, CGDisplayBlendFraction(kCGDisplayBlendNormal),
                            CGDisplayBlendFraction(kCGDisplayBlendSolidColor), 0, 0, 0, 1) == .success else {
            CGReleaseDisplayFadeReservation(reserved)
            return false
        }
        token = reserved
        return true
    }

    func back() {
        guard token != 0 else { return }
        CGDisplayFade(token, 0, CGDisplayBlendFraction(kCGDisplayBlendSolidColor), CGDisplayBlendFraction(kCGDisplayBlendNormal),
                      0, 0, 0, 1)
        CGReleaseDisplayFadeReservation(token)
        token = 0
    }
}

/// Keeps the Mac's own displays black while the privacy screen is up. The curtain is a window, and macOS doesn't keep
/// even a screen-saver-level window on every Space over the display while it slides from one Space to another (the
/// person saw each Space for about a second at each switch), nor necessarily over Mission Control, a full-screen app's
/// animation or a hot corner. A black transfer table acts on the display's output, after macOS has drawn everything,
/// so nothing drawn shows, whatever set it off: the phone, a click the phone sends, someone at the Mac.
///
/// Each display gets back exactly the table it had (Night Shift, a calibration): the newest one seen before it went
/// black. A display without a table to set, or that doesn't take one (AirPlay, Sidecar), is left to the curtain's
/// window. The tables are written down first, so a hub that crashed or was killed gives them back when it starts again
/// (`recover`). Thread-safe: the watchdog gives the displays back from its own thread when the hub's main thread stops
/// beating.
final class DisplayBlackout: @unchecked Sendable {
    /// Without a beat for this long, the hub's main thread is stuck: the watchdog gives the displays back.
    static let stall: Duration = .seconds(3)

    /// Where the tables are written down while the displays are black.
    static var markerPath: String { "\(HubPaths.root)/privacy-blackout.json" }

    private struct Entry: Codable {
        var display: UInt32
        var table: TransferTable
    }

    private let output: DisplayOutput
    private let markerPath: String?
    private let lock = NSLock()
    /// Each black display's table from before, nil when it was black already and its own isn't known.
    private var saved: [CGDirectDisplayID: TransferTable?] = [:]
    private var windowOnly: Set<CGDirectDisplayID> = []
    /// Displays whose table something put back while black, logged once each.
    private var reappeared: Set<CGDirectDisplayID> = []
    private var lastBeat: ContinuousClock.Instant?

    init(output: DisplayOutput, markerPath: String?) {
        self.output = output
        self.markerPath = markerPath
    }

    /// The displays it keeps black.
    var blackDisplays: Set<CGDirectDisplayID> { lock.withLock { Set(saved.keys) } }
    /// The displays left to the curtain's window.
    var windowOnlyDisplays: Set<CGDirectDisplayID> { lock.withLock { windowOnly } }

    /// Blacks out every display that takes it, again any whose table something else put back since (a wake, a profile
    /// change), and any that came; forgets those that went. Cheap when nothing changed: it reads each table.
    func blackOut(at now: ContinuousClock.Instant) {
        lock.withLock {
            lastBeat = now
            let displays = output.displays()
            let present = Set(displays)
            var changed = saved.keys.contains { !present.contains($0) }
            saved = saved.filter { present.contains($0.key) }
            windowOnly.formIntersection(present)
            // Read first and write the tables down, then black out: a crash in between still finds them.
            var pending: [(CGDirectDisplayID, TransferTable)] = []
            for display in displays.sorted() {
                guard let current = output.table(of: display) else {
                    if windowOnly.insert(display).inserted {
                        Log.warn("privacy screen: display \(display) has no transfer table to black out: its window covers it")
                    }
                    continue
                }
                if current.isBlack {
                    // Still black, or black already (a hub that crashed, whose `recover` didn't run): its own table
                    // isn't known, so the ColorSync profile's will be given back.
                    if saved[display] == nil {
                        saved[display] = .some(nil)
                        changed = true
                    }
                    continue
                }
                if saved[display] != nil, reappeared.insert(display).inserted {
                    Log.info("privacy screen: display \(display) showed again (macOS put its table back): black again")
                }
                pending.append((display, current))
                saved[display] = current
                changed = true
            }
            if changed { writeMarker() }
            var refused = false
            for (display, current) in pending {
                if output.setTable(.black(count: current.count), on: display), output.table(of: display)?.isBlack == true {
                    windowOnly.remove(display)
                } else {
                    // It doesn't take one: as it was, and its window covers it.
                    _ = output.setTable(current, on: display)
                    saved[display] = nil
                    refused = true
                    if windowOnly.insert(display).inserted {
                        Log.warn("privacy screen: display \(display) didn't take a black transfer table: its window covers it")
                    }
                }
            }
            if refused { writeMarker() }
        }
    }

    /// Every display back exactly as it was; how many it gave back.
    @discardableResult
    func restore() -> Int {
        lock.withLock { restoreLocked() }
    }

    private func restoreLocked() -> Int {
        lastBeat = nil
        let count = saved.count
        if saved.values.contains(where: { $0 == nil }) { output.restoreProfiles() }
        for (display, table) in saved.sorted(by: { $0.key < $1.key }) {
            guard let table else { continue }
            if !output.setTable(table, on: display) {
                Log.warn("privacy screen: couldn't give display \(display) its transfer table back")
            }
        }
        saved.removeAll()
        windowOnly.removeAll()
        reappeared.removeAll()
        removeMarker()
        return count
    }

    /// The hub's main thread is alive (the curtain's monitor, twice a second).
    func beat(at now: ContinuousClock.Instant) {
        lock.withLock { lastBeat = now }
    }

    /// From the watchdog's own thread: gives the displays back when the main thread stopped beating while they're
    /// black. The curtain's window still covers them, and its monitor blacks them out again once it beats again.
    @discardableResult
    func watchdog(at now: ContinuousClock.Instant) -> Bool {
        lock.withLock {
            guard !saved.isEmpty, let lastBeat, now - lastBeat > Self.stall else { return false }
            Log.warn("privacy screen: the hub stopped answering, so the displays are back (its window still covers them)")
            _ = restoreLocked()
            return true
        }
    }

    private func writeMarker() {
        guard let markerPath else { return }
        let entries = saved.compactMap { display, table in table.map { Entry(display: display, table: $0) } }
        guard !saved.isEmpty else {
            removeMarker()
            return
        }
        do {
            try JSONEncoder().encode(entries).write(to: URL(fileURLWithPath: markerPath), options: .atomic)
        } catch {
            Log.warn("privacy screen: couldn't write down the displays' tables: \(error.localizedDescription)")
        }
    }

    private func removeMarker() {
        guard let markerPath else { return }
        try? FileManager.default.removeItem(atPath: markerPath)
    }

    /// At launch: a hub that crashed or was killed with the displays black gives them back from what it wrote down.
    /// Only displays still black are touched (macOS may have put them back already). How many it gave back; nil when
    /// nothing was written down.
    @discardableResult
    static func recover(output: DisplayOutput, markerPath: String) -> Int? {
        guard let data = FileManager.default.contents(atPath: markerPath) else { return nil }
        try? FileManager.default.removeItem(atPath: markerPath)
        let entries = (try? JSONDecoder().decode([Entry].self, from: data)) ?? []
        let tables = Dictionary(entries.map { ($0.display, $0.table) }, uniquingKeysWith: { first, _ in first })
        let black = output.displays().filter { output.table(of: $0)?.isBlack == true }
        guard !black.isEmpty else { return 0 }
        if black.contains(where: { tables[$0] == nil }) { output.restoreProfiles() }
        for display in black {
            if let table = tables[display] { _ = output.setTable(table, on: display) }
        }
        return black.count
    }
}

/// What the privacy screen does with the displays' output, apart from its windows: black while it's up, given back
/// while someone at the Mac unlocks (so they see the unlock panel) and when it goes down; and around each Space switch
/// the hub makes, a fade to black as well. The fade is a second cover: for Macs whose displays ignore a transfer
/// table (Apple has such reports on recent Macs) and for while someone at the Mac unlocks. Used from the main thread;
/// only `watchdog` runs elsewhere.
final class PrivacyShade: @unchecked Sendable {
    /// The longest a switch's fade can last, even if the hub never gives it back.
    static let fadeLimit: Duration = .seconds(4)
    /// After the Mac reports the new Space and the curtain shows there: the displays come back this much later.
    static let margin: Duration = .milliseconds(150)
    /// The most it waits for the curtain to show on the new Space.
    static let curtainWait: Duration = .milliseconds(600)

    let blackout: DisplayBlackout
    private let fader: DisplayFader
    private(set) var isUp = false
    private(set) var unlocking = false
    private var switches = 0
    private var faded = false

    init(output: DisplayOutput, fader: DisplayFader, markerPath: String?) {
        blackout = DisplayBlackout(output: output, markerPath: markerPath)
        self.fader = fader
    }

    /// The curtain went up: the displays go black.
    func curtainUp(at now: ContinuousClock.Instant) {
        isUp = true
        unlocking = false
        blackout.blackOut(at: now)
    }

    /// The curtain went down: everything back.
    func curtainDown() {
        isUp = false
        unlocking = false
        switches = 0
        endFade()
        blackout.restore()
    }

    /// Someone at the Mac started unlocking: they see the curtain and its unlock panel.
    func unlockingBegan() {
        guard isUp else { return }
        unlocking = true
        blackout.restore()
    }

    /// They gave up, or half a minute passed: black again.
    func unlockingEnded(at now: ContinuousClock.Instant) {
        guard isUp, unlocking else { return }
        unlocking = false
        blackout.blackOut(at: now)
    }

    /// Twice a second, and when displays come or go: black again where something put a table back, and a beat.
    func tick(at now: ContinuousClock.Instant) {
        if isUp, !unlocking, switches == 0 {
            blackout.blackOut(at: now)
        } else {
            blackout.beat(at: now)
        }
    }

    /// Before a Space switch the hub makes: a fade to black, if the curtain is up. True when the switch is shaded
    /// (then `switchEnded` must follow).
    func switchBegins() -> Bool {
        guard isUp else { return false }
        if switches == 0 { faded = fader.black(for: Self.fadeLimit) }
        switches += 1
        return true
    }

    /// The Mac reported the new Space (or gave up), and the curtain shows there: the fade ends once the last switch
    /// under way has, and the tables are made black again in case the fade's end put them back.
    func switchEnded(at now: ContinuousClock.Instant) {
        guard switches > 0 else { return }
        switches -= 1
        guard switches == 0 else { return }
        endFade()
        if isUp, !unlocking { blackout.blackOut(at: now) }
    }

    private func endFade() {
        guard faded else { return }
        faded = false
        fader.back()
    }

    /// A switch with the shade around it: the answer comes as soon as the Mac is there (switching stays as quick as
    /// it was); the displays come back after, once the curtain shows on the new Space (or `curtainWait`) and a margin.
    /// `ended` finishes when they have.
    @MainActor
    func shadedSwitch(_ switcher: SpaceSwitcher, display: UInt32, index: Int?, steps: Int?,
                      curtainShown: @escaping @MainActor () -> Bool) async
        -> (outcome: SpaceSwitcher.Outcome, ended: Task<Void, Never>?) {
        let shaded = switchBegins()
        let outcome = await switcher.switchTo(display: display, index: index, steps: steps)
        guard shaded else { return (outcome, nil) }
        let ended = Task { @MainActor in
            let clock = ContinuousClock()
            let deadline = clock.now + Self.curtainWait
            while !curtainShown(), clock.now < deadline {
                try? await Task.sleep(for: .milliseconds(20))
            }
            try? await Task.sleep(for: Self.margin)
            self.switchEnded(at: clock.now)
        }
        return (outcome, ended)
    }
}
