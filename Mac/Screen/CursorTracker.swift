import AppKit
import CoreGraphics

/// The Mac's pointer for the phones that draw it themselves (`ScreenStartParams.cursor`): where it is on each display
/// they watch and what it looks like, sampled up to 120 times a second while one of them watches. Their pictures leave
/// the pointer out. The privacy screen hiding it at the Mac changes nothing here: the phone still draws it, where the
/// phone's own taps and drags put it.
@MainActor
final class CursorTracker {
    /// The pointer moved, appeared, disappeared or changed shape on a display.
    var onChange: ((CGDirectDisplayID, CursorPositionMessage) -> Void)?

    static let samplesPerSecond = 120
    /// Reading the shape costs the window server about 0.6 ms, so it's read this often while the pointer moves, and
    /// every half second while it rests (a busy pointer animates in place).
    static let shapeWhileMoving: Duration = .milliseconds(66)
    static let shapeWhileResting: Duration = .milliseconds(500)
    /// Shapes kept; a new one past this many starts over (ids keep counting, so a phone never mixes two up).
    static let keptShapes = 64

    private var displays: Set<CGDirectDisplayID> = []
    private var timer: DispatchSourceTimer?
    private var positions: [CGDirectDisplayID: CursorPositionMessage] = [:]
    private var location: CGPoint?
    private var lastMove = ContinuousClock.now
    private var lastShapeRead: ContinuousClock.Instant?
    private var shapeID: UInt32 = 0
    /// Each shape's message, encoded, by id.
    private var shapes: [UInt32: Data] = [:]
    /// Shape ids by what the shape looks like (its image, size and hot spot).
    private var fingerprints: [Int: UInt32] = [:]
    private var lastShapeID: UInt32 = 0

    /// Follows the pointer on these displays; none stops sampling.
    func track(_ displays: Set<CGDirectDisplayID>) {
        self.displays = displays
        positions = positions.filter { displays.contains($0.key) }
        guard !displays.isEmpty else {
            timer?.cancel()
            timer = nil
            return
        }
        if timer == nil {
            let timer = DispatchSource.makeTimerSource(queue: .main)
            timer.setEventHandler { [weak self] in
                MainActor.assumeIsolated { self?.sample() }
            }
            timer.schedule(deadline: .now(), repeating: .nanoseconds(1_000_000_000 / Self.samplesPerSecond),
                           leeway: .milliseconds(1))
            self.timer = timer
            timer.resume()
        }
        sample()
    }

    /// Where the pointer is on a display now, for a phone that just started watching.
    func position(on display: CGDirectDisplayID) -> CursorPositionMessage? {
        positions[display]
    }

    /// A shape's message (`CursorShapeMessage`, encoded), to send before the first position that uses it.
    func shapeMessage(_ id: UInt32) -> Data? {
        shapes[id]
    }

    private func sample() {
        guard let point = CGEvent(source: nil)?.location else { return }
        let now = ContinuousClock.now
        if point != location {
            location = point
            lastMove = now
        }
        let due = now - lastMove < .seconds(1) ? Self.shapeWhileMoving : Self.shapeWhileResting
        if lastShapeRead.map({ now - $0 >= due }) ?? true {
            lastShapeRead = now
            readShape()
        }
        // A position always refers to a shape the phone can be sent first.
        guard shapeID != 0 else { return }
        for display in displays {
            let position = Self.position(of: point, on: display, shapeID: shapeID)
            let previous = positions[display]
            let changed = previous.map { old in
                old.visible != position.visible
                    || position.visible && (Float(old.x) != Float(position.x) || Float(old.y) != Float(position.y)
                        || old.shapeID != position.shapeID)
            } ?? true
            guard changed else { continue }
            positions[display] = position
            onChange?(display, position)
        }
    }

    /// The pointer as a phone draws it on a display: as fractions of the display from its top-left corner (the inverse
    /// of how a tap's position becomes a click), visible while it's on that display.
    static func position(of point: CGPoint, on display: CGDirectDisplayID, shapeID: UInt32) -> CursorPositionMessage {
        let bounds = CGDisplayBounds(display)
        let x = (point.x - bounds.minX) / max(bounds.width - 1, 1)
        let y = (point.y - bounds.minY) / max(bounds.height - 1, 1)
        return CursorPositionMessage(displayID: display, x: min(max(x, 0), 1), y: min(max(y, 0), 1),
                                     visible: bounds.contains(point), shapeID: shapeID)
    }

    /// The pointer's current shape (the arrow until one is read; the last one while macOS shows none).
    private func readShape() {
        guard let cursor = NSCursor.currentSystem ?? (shapeID == 0 ? NSCursor.arrow : nil) else { return }
        let image = cursor.image
        // The representation nearest the sharpest display's scale.
        let scale = NSScreen.screens.map(\.backingScaleFactor).max() ?? 2
        let wanted = Double(image.size.width * scale)
        guard let representation = image.representations.min(by: {
                  abs(Double($0.pixelsWide) - wanted) < abs(Double($1.pixelsWide) - wanted)
              }),
              let picture = representation.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        var hasher = Hasher()
        hasher.combine(Double(cursor.hotSpot.x))
        hasher.combine(Double(cursor.hotSpot.y))
        hasher.combine(Double(image.size.width))
        hasher.combine(Double(image.size.height))
        hasher.combine(picture.width)
        hasher.combine(picture.height)
        if let pixels = picture.dataProvider?.data, let bytes = CFDataGetBytePtr(pixels) {
            hasher.combine(bytes: UnsafeRawBufferPointer(start: bytes, count: CFDataGetLength(pixels)))
        }
        let fingerprint = hasher.finalize()
        if let known = fingerprints[fingerprint] {
            shapeID = known
            return
        }
        guard let png = NSBitmapImageRep(cgImage: picture).representation(using: .png, properties: [:]) else { return }
        if shapes.count >= Self.keptShapes {
            // The current shape stays: a phone that starts watching now still gets it.
            shapes = shapes.filter { $0.key == shapeID }
            fingerprints = fingerprints.filter { $0.value == shapeID }
        }
        lastShapeID = lastShapeID == UInt32.max ? 1 : lastShapeID + 1
        let message = CursorShapeMessage(shapeID: lastShapeID, width: Double(image.size.width),
                                         height: Double(image.size.height), hotSpotX: Double(cursor.hotSpot.x),
                                         hotSpotY: Double(cursor.hotSpot.y), png: png)
        shapes[lastShapeID] = message.encoded()
        fingerprints[fingerprint] = lastShapeID
        shapeID = lastShapeID
    }
}
