import CoreGraphics
import Foundation
import Testing

/// The hub's live drag never leaves the Mac's button down: on a fake event poster, never real events.
@Suite("Mouse drag")
@MainActor
struct MouseDragTests {
    final class FakePoster: MouseEventPoster {
        var events: [String] = []
        func down(at point: CGPoint) { events.append("down \(Int(point.x)),\(Int(point.y))") }
        func dragged(to point: CGPoint) { events.append("drag \(Int(point.x)),\(Int(point.y))") }
        func up(at point: CGPoint) { events.append("up \(Int(point.x)),\(Int(point.y))") }
    }

    let phone = UUID(), other = UUID()

    @Test func aDragGoesDownMovesAndComesUp() {
        let poster = FakePoster()
        let session = MouseDragSession(poster: poster)
        session.start(at: CGPoint(x: 100, y: 200), by: phone)
        session.move(to: CGPoint(x: 120, y: 210), by: phone)
        session.move(to: CGPoint(x: 140, y: 230), by: phone)
        session.end(at: CGPoint(x: 150, y: 240), by: phone)
        // The lift came where the last move hadn't reached: the pointer goes there before the button comes up.
        #expect(poster.events == ["down 100,200", "drag 120,210", "drag 140,230", "drag 150,240", "up 150,240"])
        #expect(!session.isDragging)
    }

    @Test func thePhoneLeavingLetsGo() {
        let poster = FakePoster()
        let session = MouseDragSession(poster: poster)
        session.start(at: CGPoint(x: 10, y: 10), by: phone)
        session.move(to: CGPoint(x: 30, y: 40), by: phone)
        session.clientLeft(other)
        #expect(session.isDragging, "another phone leaving changes nothing")
        session.clientLeft(phone)
        #expect(poster.events.last == "up 30,40" && !session.isDragging)
    }

    @Test func anotherDragEndsTheFirst() {
        let poster = FakePoster()
        let session = MouseDragSession(poster: poster)
        session.start(at: CGPoint(x: 10, y: 10), by: phone)
        session.start(at: CGPoint(x: 500, y: 500), by: other)
        #expect(poster.events == ["down 10,10", "up 10,10", "down 500,500"])
        // The first phone's late moves and end don't touch the second's drag.
        session.move(to: CGPoint(x: 20, y: 20), by: phone)
        session.end(at: CGPoint(x: 20, y: 20), by: phone)
        #expect(session.isDragging && poster.events.count == 3)
    }

    @Test func anyOtherInputEndsTheDragFirst() {
        let poster = FakePoster()
        let session = MouseDragSession(poster: poster)
        session.interrupt()
        #expect(poster.events.isEmpty, "no drag, nothing to end")
        session.start(at: CGPoint(x: 10, y: 10), by: phone)
        session.move(to: CGPoint(x: 60, y: 70), by: phone)
        session.interrupt()
        #expect(poster.events == ["down 10,10", "drag 60,70", "up 60,70"] && !session.isDragging)
        session.end(at: CGPoint(x: 80, y: 80), by: phone)
        #expect(poster.events.count == 3, "the lost end, arriving late, changes nothing")
    }

    @Test func aFingerHeldStillKeepsTheDrag() async throws {
        let poster = FakePoster()
        let session = MouseDragSession(poster: poster, idleLimit: .milliseconds(150))
        session.start(at: CGPoint(x: 10, y: 10), by: phone)
        // The phone's "still here" moves: to where the pointer is, more often than the limit.
        for _ in 0..<6 {
            try await Task.sleep(for: .milliseconds(60))
            session.move(to: CGPoint(x: 10, y: 10), by: phone)
        }
        #expect(session.isDragging, "a finger held still keeps the drag")
        #expect(poster.events == ["down 10,10"], "and posts nothing")
        session.end(at: CGPoint(x: 10, y: 10), by: phone)
        #expect(poster.events == ["down 10,10", "up 10,10"])
    }

    @Test func theLogSaysHowEachDragStartedAndWhatEndedIt() async throws {
        var lines: [String] = []
        let session = MouseDragSession(poster: FakePoster(), idleLimit: .milliseconds(150), log: { lines.append($0) })
        session.start(at: CGPoint(x: 10, y: 10), by: phone, how: "picked up by a hold")
        session.move(to: CGPoint(x: 13, y: 14), by: phone)
        session.move(to: CGPoint(x: 13, y: 14), by: phone)
        session.end(at: CGPoint(x: 13, y: 24), by: phone)
        #expect(lines.count == 2)
        #expect(lines.first == "drag: started (picked up by a hold) at 10,10")
        #expect(lines.last?.hasPrefix("drag: ended by the lift after 0.") == true, "\(lines)")
        #expect(lines.last?.hasSuffix(", 2 moves, 15 pt") == true, "a still move isn't one; the lift is: \(lines)")

        session.start(at: .zero, by: phone)
        session.clientLeft(phone)
        session.start(at: .zero, by: phone)
        session.start(at: .zero, by: other)
        session.interrupt()
        session.start(at: .zero, by: phone)
        try await Task.sleep(for: .milliseconds(400))
        let endings = lines.filter { $0.hasPrefix("drag: ended by ") }.map { line in
            String(line.dropFirst("drag: ended by ".count).components(separatedBy: " after ")[0])
        }
        #expect(endings == ["the lift", "the phone leaving", "another drag", "other input",
                            "the timeout (no word from the phone for 0.15 s)"], "\(lines)")
        #expect(lines.contains("drag: started (moving) at 0,0"))
    }

    @Test func aPickUpPressesOnlyOnceTheFingerMovesThenDragsAtOnce() {
        let poster = FakePoster()
        var lines: [String] = []
        let session = MouseDragSession(poster: poster, log: { lines.append($0) })
        session.start(at: CGPoint(x: 100, y: 200), by: phone, how: "picked up by a hold", pressOnMove: true)
        // Resting, and the finger's small wobble: no press yet, and the pointer stays put.
        session.move(to: CGPoint(x: 100, y: 200), by: phone)
        session.move(to: CGPoint(x: 104, y: 203), by: phone)
        session.move(to: CGPoint(x: 96, y: 207), by: phone)
        #expect(poster.events.isEmpty && session.isDragging && !session.pressed, "\(poster.events)")
        // It moves off: the press where the drag started, and the first step together.
        session.move(to: CGPoint(x: 110, y: 212), by: phone)
        #expect(poster.events == ["down 100,200", "drag 110,212"])
        session.move(to: CGPoint(x: 140, y: 240), by: phone)
        session.end(at: CGPoint(x: 140, y: 240), by: phone)
        #expect(poster.events == ["down 100,200", "drag 110,212", "drag 140,240", "up 140,240"])
        #expect(lines.last?.hasSuffix(", 2 moves, 57 pt") == true, "\(lines)")
    }

    @Test func aPickUpThatNeverMovesPressesNothing() async throws {
        let poster = FakePoster()
        var lines: [String] = []
        let session = MouseDragSession(poster: poster, idleLimit: .milliseconds(150), log: { lines.append($0) })
        // Lifted where it was: nothing at all, not even a click.
        session.start(at: CGPoint(x: 10, y: 10), by: phone, how: "picked up by a hold", pressOnMove: true)
        session.move(to: CGPoint(x: 15, y: 12), by: phone)
        session.end(at: CGPoint(x: 15, y: 12), by: phone)
        #expect(poster.events.isEmpty && !session.isDragging)
        #expect(lines.last?.hasSuffix("0 moves, 0 pt (never pressed)") == true, "\(lines)")
        // The phone leaving, another drag, other input and the timeout let go of nothing either.
        session.start(at: .zero, by: phone, pressOnMove: true)
        session.clientLeft(phone)
        session.start(at: .zero, by: phone, pressOnMove: true)
        session.start(at: CGPoint(x: 50, y: 50), by: other, pressOnMove: true)
        session.interrupt()
        session.start(at: .zero, by: phone, pressOnMove: true)
        try await Task.sleep(for: .milliseconds(400))
        #expect(poster.events.isEmpty && !session.isDragging, "\(poster.events)")
    }

    @Test func aPickUpFlickedAwayPressesDragsAndDrops() {
        let poster = FakePoster()
        let session = MouseDragSession(poster: poster)
        session.start(at: CGPoint(x: 100, y: 200), by: phone, how: "picked up by a hold", pressOnMove: true)
        // The lift is the first word from the phone after the pick-up, far away.
        session.end(at: CGPoint(x: 300, y: 260), by: phone)
        #expect(poster.events == ["down 100,200", "drag 300,260", "up 300,260"])
    }

    @Test func aQuietDragTimesOut() async throws {
        let poster = FakePoster()
        let session = MouseDragSession(poster: poster, idleLimit: .milliseconds(150))
        session.start(at: CGPoint(x: 10, y: 10), by: phone)
        try await Task.sleep(for: .milliseconds(100))
        session.move(to: CGPoint(x: 20, y: 20), by: phone)
        try await Task.sleep(for: .milliseconds(100))
        #expect(session.isDragging, "a move keeps it going")
        try await Task.sleep(for: .milliseconds(200))
        #expect(!session.isDragging && poster.events.last == "up 20,20", "\(poster.events)")
    }
}
