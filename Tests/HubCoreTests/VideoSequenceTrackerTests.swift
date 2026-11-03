import Testing

/// Which video frames the phone decodes: everything in sequence, nothing after a gap or a failed frame until a refresh
/// frame or a keyframe, and a request for one meanwhile.
@Suite("Video sequence")
struct VideoSequenceTrackerTests {
    static let key: VideoFrameMessage.Flags = [.keyframe, .refresh]
    static let refresh: VideoFrameMessage.Flags = .refresh

    /// A tracker fed as the phone feeds it.
    final class Phone {
        var tracker = VideoSequenceTracker()

        /// Offers frames in turn, each one taken decoding fine; returns which were taken.
        func receive(_ frames: [(UInt32, VideoFrameMessage.Flags)]) -> [Bool] {
            frames.map { sequence, flags in
                guard tracker.shouldDecode(sequence: sequence, flags: flags) else { return false }
                tracker.decoded(sequence: sequence, flags: flags)
                return true
            }
        }

        /// Offers a frame that's taken but fails to decode; returns whether it was taken.
        func receiveBroken(_ sequence: UInt32, _ flags: VideoFrameMessage.Flags) -> Bool {
            guard tracker.shouldDecode(sequence: sequence, flags: flags) else { return false }
            tracker.failed()
            return true
        }
    }

    @Test func framesInSequenceDecode() {
        let phone = Phone()
        #expect(phone.tracker.newestDecoded == nil && !phone.tracker.needsRefresh)
        #expect(phone.receive([(1, Self.key)] + (UInt32(2)...20).map { ($0, []) }).allSatisfy { $0 })
        #expect(phone.tracker.newestDecoded == 20)
        #expect(!phone.tracker.needsRefresh)
    }

    /// The hub skipped frames: the ones after the gap would show a broken picture, so they wait for a refresh frame.
    @Test func aGapWaitsForARefreshFrame() {
        let phone = Phone()
        #expect(phone.receive([(1, Self.key), (3, [])]) == [true, false], "frame 2 is missing")
        #expect(phone.tracker.needsRefresh)
        #expect(phone.receive([(4, [])]) == [false], "in sequence after the gap, but built on what's missing")
        #expect(phone.tracker.newestDecoded == 1)
        #expect(phone.receive([(5, Self.refresh), (6, [])]) == [true, true], "a refresh frame is safe to start from")
        #expect(!phone.tracker.needsRefresh)
        #expect(phone.tracker.newestDecoded == 6)
    }

    @Test func aFailedFrameWaitsForARefreshFrame() {
        let phone = Phone()
        #expect(phone.receive([(10, Self.key)]) == [true])
        #expect(phone.receiveBroken(11, []))
        #expect(phone.tracker.needsRefresh)
        #expect(phone.receive([(12, [])]) == [false])
        #expect(phone.receiveBroken(13, Self.refresh))
        #expect(phone.tracker.needsRefresh, "a refresh frame that fails keeps asking")
        #expect(phone.receive([(14, Self.key)]) == [true], "a keyframe always decodes")
        #expect(!phone.tracker.needsRefresh)
        #expect(phone.tracker.newestDecoded == 14)
    }

    /// Joining a stream part-way: its first frame needs others before it, so the phone asks for a refresh.
    @Test func aStreamJoinedPartWayAsksForARefresh() {
        let phone = Phone()
        #expect(phone.receive([(40, [])]) == [false])
        #expect(phone.tracker.needsRefresh)
        #expect(phone.receive([(41, Self.refresh), (42, [])]) == [true, true])
        #expect(!phone.tracker.needsRefresh)
    }

    /// The hub's encoder started over (new settings): its keyframe numbers from scratch, and that's fine.
    @Test func aKeyframeStartsOverWhateverItsNumber() {
        let phone = Phone()
        #expect(phone.receive([(500, Self.key), (501, []), (1, Self.key), (2, [])]) == [true, true, true, true])
        #expect(!phone.tracker.needsRefresh)
    }

    @Test func numbersWrapAround() {
        let phone = Phone()
        #expect(phone.receive([(.max - 1, Self.key), (.max, []), (0, []), (1, [])]) == [true, true, true, true])
        #expect(!phone.tracker.needsRefresh)
    }

    @Test func aRepeatedOrOlderFrameIsAGap() {
        let phone = Phone()
        #expect(phone.receive([(7, Self.key), (7, []), (8, [])]) == [true, false, false])
        #expect(phone.tracker.needsRefresh)
    }

    @Test func resetForgetsTheStream() {
        let phone = Phone()
        #expect(phone.receive([(3, [])]) == [false])
        #expect(phone.tracker.needsRefresh)
        phone.tracker.reset()
        #expect(phone.tracker == VideoSequenceTracker())
        #expect(phone.receive([(1, Self.key)]) == [true])
    }
}
