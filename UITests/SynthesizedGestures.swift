import XCTest

/// Gestures XCUITest's API can't make, built from XCTest's own event records (what its taps and drags are made of): a
/// tap, then a second touch inside the real double-tap window that rests, moves and lifts, played as one gesture with
/// a finger's timing. The records are XCTest's private classes, looked up at run time; a test that needs them is
/// skipped where they aren't there.
@MainActor
enum SynthesizedGesture {
    private typealias AllocFn = @convention(c) (AnyClass, Selector) -> AnyObject
    private typealias InitPathFn = @convention(c) (AnyObject, Selector, CGPoint, Double) -> AnyObject
    private typealias OffsetFn = @convention(c) (AnyObject, Selector, Double) -> Void
    private typealias MoveFn = @convention(c) (AnyObject, Selector, CGPoint, Double) -> Void
    private typealias InitRecordFn = @convention(c) (AnyObject, Selector, NSString, Int) -> AnyObject
    private typealias AddPathFn = @convention(c) (AnyObject, Selector, AnyObject) -> Void
    private typealias SharedFn = @convention(c) (AnyClass, Selector) -> AnyObject
    private typealias SynthesizeFn = @convention(c) (AnyObject, Selector, AnyObject, @convention(block) (Bool, NSError?) -> Void) -> Void

    private static let path: AnyClass? = NSClassFromString("XCPointerEventPath")
    private static let record: AnyClass? = NSClassFromString("XCSynthesizedEventRecord")
    private static let session: AnyClass? = NSClassFromString("XCTRunnerDaemonSession")

    static var isAvailable: Bool {
        guard let path, let record, let session else { return false }
        return path.instancesRespond(to: NSSelectorFromString("initForTouchAtPoint:offset:"))
            && path.instancesRespond(to: NSSelectorFromString("liftUpAtOffset:"))
            && path.instancesRespond(to: NSSelectorFromString("moveToPoint:atOffset:"))
            && record.instancesRespond(to: NSSelectorFromString("initWithName:interfaceOrientation:"))
            && record.instancesRespond(to: NSSelectorFromString("addPointerEventPath:"))
            && session.instancesRespond(to: NSSelectorFromString("synthesizeEvent:completion:"))
            && (session as AnyObject).responds(to: NSSelectorFromString("sharedSession"))
    }

    /// A tap at `start`, the second touch `gap` seconds after the tap's lift at the same spot, still for `hold`, then a
    /// move to `end` over `move` at a hand's pace, a rest of `rest`, and the lift. Points are the screen's, upright.
    static func doubleTapHoldDrag(from start: CGPoint, to end: CGPoint, tap: TimeInterval = 0.06, gap: TimeInterval,
                                  hold: TimeInterval, move: TimeInterval = 0.6, rest: TimeInterval = 0.3,
                                  in test: XCTestCase) throws {
        guard isAvailable, let pathClass = path, let recordClass = record, let sessionClass = session else {
            throw XCTSkip("XCTest's event records aren't there")
        }
        // One path a touch: the tap, then the second touch, which starts `gap` after the tap's lift.
        let tapPath = make(pathClass, "initForTouchAtPoint:offset:") { (fn: InitPathFn, object, sel) in fn(object, sel, start, 0) }
        call(tapPath, "liftUpAtOffset:", tap)
        let second = tap + gap
        let holdPath = make(pathClass, "initForTouchAtPoint:offset:") { (fn: InitPathFn, object, sel) in fn(object, sel, start, second) }
        let moving = second + hold
        moveTo(holdPath, start, moving)
        let steps = 30
        for step in 1...steps {
            let t = Double(step) / Double(steps)
            moveTo(holdPath, CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t), moving + move * t)
        }
        call(holdPath, "liftUpAtOffset:", moving + move + rest)

        let name = "double tap, hold \(hold) s, drag" as NSString
        let event = make(recordClass, "initWithName:interfaceOrientation:") { (fn: InitRecordFn, object, sel) in fn(object, sel, name, 1) }
        let add = NSSelectorFromString("addPointerEventPath:")
        for path in [tapPath, holdPath] {
            unsafeBitCast(event.method(for: add), to: AddPathFn.self)(event, add, path)
        }

        let sharedSelector = NSSelectorFromString("sharedSession")
        let classMethod = (sessionClass as AnyObject).method(for: sharedSelector)
        let shared = unsafeBitCast(classMethod, to: SharedFn.self)(sessionClass, sharedSelector)
        let done = test.expectation(description: "the gesture played")
        final class Outcome: @unchecked Sendable { var error: NSError? }
        let outcome = Outcome()
        // The reply is (BOOL, NSError *): whether it played, and why not.
        let completion: @convention(block) (Bool, NSError?) -> Void = { played, error in
            outcome.error = played ? nil : (error ?? NSError(domain: "SynthesizedGesture", code: 1))
            done.fulfill()
        }
        let synthesize = NSSelectorFromString("synthesizeEvent:completion:")
        unsafeBitCast(shared.method(for: synthesize), to: SynthesizeFn.self)(shared, synthesize, event, completion)
        test.wait(for: [done], timeout: moving + move + rest + 30)
        if let error = outcome.error { throw error }
    }

    private static func make<F>(_ cls: AnyClass, _ initializer: String, _ body: (F, AnyObject, Selector) -> AnyObject) -> AnyObject {
        let allocSelector = NSSelectorFromString("alloc")
        let allocated = unsafeBitCast((cls as AnyObject).method(for: allocSelector), to: AllocFn.self)(cls, allocSelector)
        let sel = NSSelectorFromString(initializer)
        return body(unsafeBitCast(allocated.method(for: sel), to: F.self), allocated, sel)
    }

    private static func call(_ object: AnyObject, _ name: String, _ offset: Double) {
        let sel = NSSelectorFromString(name)
        unsafeBitCast(object.method(for: sel), to: OffsetFn.self)(object, sel, offset)
    }

    private static func moveTo(_ object: AnyObject, _ point: CGPoint, _ offset: Double) {
        let sel = NSSelectorFromString("moveToPoint:atOffset:")
        unsafeBitCast(object.method(for: sel), to: MoveFn.self)(object, sel, point, offset)
    }
}
