import Foundation
import Testing

/// The Screen tab's Spaces pager: a swipe asks the Mac once, the page follows the Mac whoever switches, and a page is live
/// only once the Mac has got there. Their three Spaces: a desktop and two full-screen apps.
@Suite("Spaces follower")
struct SpaceFollowerTests {
    static let desktop: UInt64 = 3, mail: UInt64 = 41, terminal: UInt64 = 57

    /// The Mac's Spaces with `current` current.
    static func spaces(current: UInt64) -> [SpaceInfo] {
        [SpaceInfo(id: desktop, index: 0, isFullscreen: false, isCurrent: current == desktop, title: nil),
         SpaceInfo(id: mail, index: 1, isFullscreen: true, isCurrent: current == mail, title: "Mail"),
         SpaceInfo(id: terminal, index: 2, isFullscreen: true, isCurrent: current == terminal, title: "Terminal")]
    }

    func follower(on current: UInt64) -> SpaceFollower {
        var follower = SpaceFollower()
        _ = follower.received(Self.spaces(current: current))
        return follower
    }

    @Test func aSwipeSwitchesTheMacOnce() {
        var pager = follower(on: Self.desktop)
        #expect(pager.page == Self.desktop)
        #expect(pager.settled(on: Self.mail) == .switchMac(index: 1, page: Self.mail))
        // The pager reporting the same page again (it settles twice) asks nothing more.
        #expect(pager.settled(on: Self.mail) == .none)
        #expect(!pager.isLive(Self.mail), "its snapshot shows until the Mac has got there")
        #expect(!pager.invitesSwitch(Self.mail), "no banner on the page the Mac is going to")
        #expect(pager.switched(Self.spaces(current: Self.mail)) == .none)
        #expect(pager.isLive(Self.mail) && pager.page == Self.mail)
    }

    /// The Mac takes its time, and meanwhile an update still has the old Space current: the page doesn't go back.
    @Test func aSlowSwitchDoesntBounce() {
        var pager = follower(on: Self.desktop)
        #expect(pager.settled(on: Self.terminal) == .switchMac(index: 2, page: Self.terminal))
        #expect(pager.received(Self.spaces(current: Self.desktop)) == .none, "no scroll back while the switch is on its way")
        #expect(pager.page == Self.terminal)
        // The update that has it there makes the page live before the answer.
        #expect(pager.received(Self.spaces(current: Self.terminal)) == .none)
        #expect(pager.isLive(Self.terminal))
        #expect(pager.switched(Self.spaces(current: Self.terminal)) == .none)
        #expect(pager.page == Self.terminal && pager.switching == nil)
    }

    /// Someone at the Mac switches (trackpad, keyboard, Mission Control): the page follows, live, with no banner.
    @Test func thePageFollowsTheMac() {
        var pager = follower(on: Self.desktop)
        #expect(pager.received(Self.spaces(current: Self.mail)) == .scroll(to: Self.mail))
        #expect(pager.page == Self.mail && pager.isLive(Self.mail) && !pager.invitesSwitch(Self.mail))
        #expect(pager.invitesSwitch(Self.desktop), "the desktop it left invites a swipe again")
        // The pager getting there reports the page: the Mac is there already, so nothing is asked.
        #expect(pager.settled(on: Self.mail) == .none)
    }

    @Test func aFailedSwitchGoesBack() {
        var pager = follower(on: Self.desktop)
        _ = pager.settled(on: Self.mail)
        #expect(pager.switched(nil) == .scroll(to: Self.desktop))
        // The Mac answered but stayed where it was.
        _ = pager.settled(on: Self.mail)
        #expect(pager.switched(Self.spaces(current: Self.desktop)) == .scroll(to: Self.desktop))
        #expect(pager.isLive(Self.desktop))
    }

    /// A second swipe while the first switch is on its way goes next, once; swiping back to it cancels the next.
    @Test func swipesDuringASwitchQueue() {
        var pager = follower(on: Self.desktop)
        _ = pager.settled(on: Self.mail)
        #expect(pager.settled(on: Self.terminal) == .none)
        #expect(!pager.invitesSwitch(Self.terminal) && !pager.isLive(Self.mail))
        #expect(pager.switched(Self.spaces(current: Self.mail)) == .switchMac(index: 2, page: Self.terminal))
        #expect(pager.switched(Self.spaces(current: Self.terminal)) == .none)
        #expect(pager.isLive(Self.terminal))
        // Back and forth while a switch is on its way: only the last place counts.
        _ = pager.settled(on: Self.mail)
        #expect(pager.settled(on: Self.desktop) == .none)
        #expect(pager.settled(on: Self.mail) == .none, "back to the Space on its way: nothing queued")
        #expect(pager.switched(Self.spaces(current: Self.mail)) == .none)
    }

    /// The Spaces bar steps from where the pager is going, works zoomed or in Drag to Scroll alike (no finger on the
    /// pager), and never goes past either end.
    @Test func theSpacesBarSteps() {
        var pager = follower(on: Self.desktop)
        #expect(pager.step(-1) == .none, "nothing before the first")
        #expect(pager.step(1) == .switchMac(index: 1, page: Self.mail))
        #expect(pager.step(1) == .scroll(to: Self.terminal), "a second step while the first is on its way: queued")
        #expect(pager.step(1) == .none, "nothing after the last")
        #expect(pager.switched(Self.spaces(current: Self.mail)) == .switchMac(index: 2, page: Self.terminal))
        #expect(pager.switched(Self.spaces(current: Self.terminal)) == .none)
        #expect(pager.step(-1) == .switchMac(index: 1, page: Self.mail))
    }

    /// Their photo: the pager on the desktop, which the Mac was showing, while the phone thought a full-screen Space was
    /// current, so the desktop page asked to be swiped to. With the Mac's updates it can't stay that way.
    @Test func thePhotosStateMends() {
        var pager = follower(on: Self.mail)
        // A swipe to the desktop the phone never heard the answer to (an older hub's early reply).
        _ = pager.settled(on: Self.desktop)
        _ = pager.switched(Self.spaces(current: Self.mail))
        #expect(pager.page == Self.mail, "an early answer takes it back to Mail")
        // The Mac's own update, once it's on the desktop, brings the pager there, live.
        #expect(pager.received(Self.spaces(current: Self.desktop)) == .scroll(to: Self.desktop))
        #expect(pager.isLive(Self.desktop) && !pager.invitesSwitch(Self.desktop))
    }
}
