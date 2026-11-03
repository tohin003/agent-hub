import Foundation
import Testing

/// Rate control piece by piece (trendline, overuse detector, AIMD, loss-based control, probes), the arrival reports
/// it reads, and the pacer that applies it.
@Suite("Rate control and pacing")
struct CongestionControlTests {
    @Test func trendlineIsTheLeastSquaresSlope() throws {
        let points = (0..<20).map { (x: Double($0) * 10, y: 3 + 0.25 * Double($0) * 10) }
        #expect(abs(try #require(TrendlineEstimator.slope(points)) - 0.25) < 1e-12)
        #expect(TrendlineEstimator.slope([(x: 1, y: 2), (x: 1, y: 5)]) == nil)
    }

    /// Groups 10 ms apart: arriving 10 ms apart is normal, 12 ms apart (a queue growing 20%) is overuse within a few
    /// groups, 7 ms apart (the queue draining) is underuse.
    @Test func growingDelayIsOverAndShrinkingDelayUnderuse() {
        var interArrival = InterArrival()
        var trendline = TrendlineEstimator()
        var sendTime: Int64 = 0
        var arrivalTime: Int64 = 100_000
        func feed(_ groups: Int, arrivalSpacing: Int64) -> [BandwidthUsage] {
            var states: [BandwidthUsage] = []
            for _ in 0..<groups {
                for offset: Int64 in [0, 1_000] {
                    if let delta = interArrival.add(send: sendTime + offset, arrival: arrivalTime + offset, size: 1200) {
                        trendline.update(arrivalDeltaMs: Double(delta.arrival) / 1000, sendDeltaMs: Double(delta.send) / 1000,
                                         arrivalMs: Double(arrivalTime + offset) / 1000)
                    }
                }
                sendTime += 10_000
                arrivalTime += arrivalSpacing
                states.append(trendline.state)
            }
            return states
        }
        let steady = feed(80, arrivalSpacing: 10_000)
        #expect(steady.allSatisfy { $0 == .normal })
        let growing = feed(40, arrivalSpacing: 12_000)
        let overuseAfter = growing.firstIndex(of: .overusing)
        #expect(overuseAfter != nil && overuseAfter.map { $0 <= 12 } == true, "overuse after \(String(describing: overuseAfter)) groups")
        let draining = feed(40, arrivalSpacing: 7_000)
        #expect(draining.contains(.underusing))
        reportMetric("overuse detected \(overuseAfter ?? -1) groups (\((overuseAfter ?? 0) * 12) ms) into a 20% overshoot; "
            + "threshold then \(String(format: "%.1f", trendline.threshold))")
    }

    @Test func aimdCutsToEightyFivePercentOfWhatGotThroughThenGrowsByAPacketPerResponseTime() {
        var aimd = AimdRateControl(start: 5_000_000, min: 100_000, max: 10_000_000)
        aimd.roundTrip = 50_000
        #expect(abs(aimd.update(usage: .overusing, throughput: 4_000_000, now: 1_000_000) - 3_400_000) < 1)
        #expect(aimd.linkCapacity == 4_000_000)
        #expect(!aimd.timeToReduceFurther(now: 1_040_000, throughput: 3_000_000), "once per round trip")
        #expect(aimd.timeToReduceFurther(now: 1_050_000, throughput: 3_000_000))
        #expect(aimd.timeToReduceFurther(now: 1_010_000, throughput: 1_000_000), "at once when far less gets through")
        var now: Int64 = 1_025_000
        _ = aimd.update(usage: .normal, throughput: 3_400_000, now: now)
        let start = aimd.current
        for _ in 0..<40 {
            now += 25_000
            _ = aimd.update(usage: .normal, throughput: 3_400_000, now: now)
        }
        // 3.4 Mbit/s at 30 fps: 12 packets of ≈9,444 bits per frame, over a 150 ms response time: ≈63 kbit/s a second.
        #expect(abs((aimd.current - start) - 62_963) < 2_000, "additive near the known capacity: \(aimd.current - start)")
    }

    @Test func aimdGrowsEightPercentASecondWhileTheCapacityIsUnknown() {
        var aimd = AimdRateControl(start: 1_000_000, min: 100_000, max: 10_000_000)
        _ = aimd.update(usage: .normal, throughput: 1_000_000, now: 0)
        let start = aimd.current
        var now: Int64 = 0
        for _ in 0..<40 {
            now += 25_000
            _ = aimd.update(usage: .normal, throughput: aimd.current, now: now)
        }
        #expect(abs(aimd.current / start - 1.08) < 0.002)
        var limited = AimdRateControl(start: 1_000_000, min: 100_000, max: 10_000_000)
        for step in 0..<100 { _ = limited.update(usage: .normal, throughput: 200_000, now: Int64(step) * 25_000) }
        #expect(limited.current == 1_000_000, "no growth past 1.5× what actually gets through")
    }

    @Test func lossBasedControlHoldsBetweenItsThresholdsAndCutsAbove() {
        var control = LossBasedControl(start: 4_000_000, min: 300_000, max: 10_000_000, lowLoss: 0.02, highLoss: 0.10)
        control.updateDelayLimit(10_000_000, now: 0)
        control.onPackets(lost: 1, total: 100, now: 100_000)
        #expect(control.current == 4_321_000, "1%: 8% over the last second's lowest, plus 1 kbit/s")
        control.onPackets(lost: 5, total: 100, now: 200_000)
        #expect(control.current == 4_321_000, "5%: hold")
        control.onPackets(lost: 20, total: 100, now: 300_000)
        #expect(abs(control.current - 3_888_900) < 1, "20%: down by half the loss rate")
        control.onPackets(lost: 20, total: 100, now: 400_000)
        #expect(abs(control.current - 3_888_900) < 1, "at most once per 300 ms + round trip")
        control.onPackets(lost: 20, total: 100, now: 900_000)
        #expect(abs(control.current - 3_500_010) < 1)
        control.onPackets(lost: 5, total: 10, now: 1_000_000)
        #expect(abs(control.current - 3_500_010) < 1, "fewer than 20 packets decide nothing")
        control.updateDelayLimit(2_000_000, now: 1_100_000)
        #expect(control.current == 2_000_000, "never above the delay-based estimate")
    }

    @Test func aProbeShowsTheBottleneck() throws {
        let spec = ProbeCluster(id: 1, bitrate: 6_000_000)
        #expect(spec.minBytes == 11_250 && spec.minPackets == 5)
        var estimator = ProbeBitrateEstimator()
        for index in 0..<10 {
            estimator.add(PacketResult(number: UInt64(index), sendTime: Int64(index) * 1_600, size: 1200,
                                       arrival: 50_000 + Int64(index) * 3_200, probeCluster: 1), spec: spec)
        }
        let first = estimator.takeEstimate()
        let saturated = try #require(first)
        #expect(abs(saturated - 2_850_000) < 1_000, "95% of the 3 Mbit/s it arrived at: \(saturated)")
        #expect(estimator.takeEstimate() == nil)
        for index in 0..<10 {
            estimator.add(PacketResult(number: UInt64(100 + index), sendTime: Int64(index) * 1_600, size: 1200,
                                       arrival: 50_000 + Int64(index) * 1_600, probeCluster: 2), spec: ProbeCluster(id: 2, bitrate: 6_000_000))
        }
        let carried = estimator.takeEstimate()
        #expect(abs(try #require(carried) - 6_000_000) < 1_000, "carried in full: the probe's own rate")
    }

    @Test func reportsCoverEveryNumberAndKeepArrivalTimes() throws {
        var builder = FeedbackBuilder()
        var random = SeededGenerator(seed: 41)
        var truth: [UInt64: Int64?] = [:]
        var time: Int64 = 10_000_000
        for number in UInt64(1)...1000 {
            time += Int64(200 + random.next() % 3000)
            let arrived = number == 1 || number == 1000 || !random.chance(0.05)
            truth[number] = arrived ? time : nil
            if arrived { builder.record(number: number, arrival: time) }
        }
        let keys = try TransportPacketTests.keys()
        var sealer = PacketSealer(keys: keys, direction: .phoneToHub)
        var opener = PacketOpener(keys: keys, direction: .phoneToHub)
        var covered: [UInt64] = []
        for report in builder.build(now: time) {
            let opened = try opener.open(try sealer.seal(.feedback(report), sendTime: 0).datagram).get()
            guard case .feedback(let feedback) = opened.message else {
                Issue.record("not a report")
                continue
            }
            #expect(feedback.arrivals.count <= FeedbackBuilder.maxPacketsPerFeedback)
            for (offset, arrival) in feedback.arrivals.enumerated() {
                let number = feedback.baseNumber + UInt64(offset)
                covered.append(number)
                let expected = try #require(truth[number])
                #expect((arrival == nil) == (expected == nil), "packet \(number)")
                if let arrival, let expected { #expect(abs(arrival - expected) <= 125) }
            }
        }
        #expect(covered == Array(1...1000), "every number once, in order")
        builder.record(number: 500, arrival: time + 1)
        #expect(builder.pendingCount == 0, "too late: already reported")

        var outage = FeedbackBuilder()
        for number: UInt64 in [1, 2, 900] { outage.record(number: number, arrival: Int64(number) * 1000) }
        let runs = outage.build(now: 0)
        #expect(runs.map(\.baseNumber) == [1, 900] && runs.map(\.arrivals.count) == [2, 1], "an outage isn't reported number by number")
    }

    @Test func theSentHistoryMatchesEachPacketOnce() {
        var history = SentPacketHistory()
        history.record(number: 5, sendTime: 100, size: 1200, probeCluster: 2)
        #expect(history.take(5)?.probeCluster == 2)
        #expect(history.take(5) == nil, "once")
        #expect(history.take(6) == nil)
        history.record(number: 7, sendTime: 1, size: 1)
        history.record(number: 7 + UInt64(SentPacketHistory.capacity), sendTime: 2, size: 2)
        #expect(history.take(7) == nil, "overwritten")
        #expect(history.take(7 + UInt64(SentPacketHistory.capacity))?.size == 2)
    }

    // MARK: Pacer

    /// A video piece whose datagram is exactly 1,200 bytes.
    static func piece(_ frameID: UInt32 = 1) -> TransportMessage {
        .video(VideoFragment(stream: 0, sequence: 1, frameID: frameID, index: 0, count: 1, flags: [], fecBlockSize: 0,
                             payload: Data(count: TransportWire.maxPayloadSize - VideoFragment.headerSize)))
    }

    static let sound = TransportMessage.audio(AudioBundle(stream: 1, sequence: 1, timestamp: 0, duration: 10_000,
                                                          frames: [Data(count: 160)]))

    /// Drives a pacer until `count` items went or nothing is left; returns when each went.
    static func drain(_ pacer: Pacer, count: Int, from start: Int64) -> [(time: Int64, item: Pacer.Item)] {
        var sent: [(time: Int64, item: Pacer.Item)] = []
        var now = start
        while sent.count < count {
            sent += pacer.poll(now: now).map { (now, $0) }
            guard let next = pacer.nextSendTime(now: now) else { break }
            now = max(next, now + 1)
        }
        return sent
    }

    @Test func aFrameIsSpreadAtThePacingRate() {
        let pacer = Pacer(pacingRate: 10_000_000, maxVideoQueueDelay: 1_000_000)
        #expect(Self.piece().datagramSize == 1200)
        pacer.enqueueFrame(Array(repeating: Self.piece(), count: 20), frameID: 1, refresh: true, expires: .max, now: 0)
        let sent = Self.drain(pacer, count: 20, from: 0)
        #expect(sent.count == 20)
        #expect(sent.prefix(6).allSatisfy { $0.time == 0 } && sent[6].time > 0, "a 5 ms burst allowance: 6,250 bytes")
        let gaps = zip(sent.dropFirst(7), sent.dropFirst(6)).map { $0.time - $1.time }
        #expect(gaps.allSatisfy { (958...962).contains($0) }, "then one 1,200-byte packet per 960 µs: \(gaps)")
        #expect((12_000...15_000).contains(sent.last?.time ?? 0))
    }

    @Test func soundAndControlNeverWaitAndResendsGoBeforePictures() {
        let pacer = Pacer(pacingRate: 2_000_000, maxVideoQueueDelay: 1_000_000)
        pacer.enqueueFrame(Array(repeating: Self.piece(), count: 50), frameID: 1, refresh: true, expires: .max, now: 0)
        #expect(pacer.poll(now: 0).count == 2, "the burst allowance is spent")
        pacer.enqueue(Self.sound, priority: .audio, now: 1_000)
        pacer.enqueue(Self.piece(1), priority: .retransmission, now: 1_000, frameID: 1)
        pacer.enqueue(.keepalive(TransportKeepalive()), priority: .control, now: 1_000)
        #expect(pacer.nextSendTime(now: 1_000) == 1_000, "sound doesn't wait for the budget")
        let now = pacer.poll(now: 1_000)
        #expect(now.map(\.priority) == [.control, .audio])
        let next = Self.drain(pacer, count: 2, from: 1_001)
        #expect(next.first?.item.priority == .retransmission, "a resend before the rest of the picture")
    }

    /// 25 ms of backlog at 4 Mbit/s is 12,500 bytes: a frame on top of 14,400 is refused, and so is every frame after it
    /// until a refresh frame, which drops what's still queued.
    @Test func aFullBacklogRefusesFramesUntilARefreshFrame() {
        let pacer = Pacer(pacingRate: 4_000_000, maxVideoQueueDelay: 25_000)
        #expect(pacer.admitFrame(refresh: false, now: 0) == .accepted)
        pacer.enqueueFrame(Array(repeating: Self.piece(), count: 12), frameID: 1, refresh: false, expires: .max, now: 0)
        #expect(pacer.backlogDelay == 28_800)
        #expect(pacer.admitFrame(refresh: false, now: 0) == .dropped(.queueFull))
        #expect(pacer.admitFrame(refresh: false, now: 5_000) == .dropped(.awaitingRefresh))
        _ = pacer.poll(now: 30_000)
        #expect(pacer.admitFrame(refresh: false, now: 30_000) == .dropped(.awaitingRefresh), "only a refresh frame lifts it")
        #expect(pacer.admitFrame(refresh: true, now: 30_000) == .accepted)
        #expect(pacer.queuedCount(.video) == 0, "the rest of frame 1 is no longer needed")
        #expect(pacer.admitFrame(refresh: false, now: 30_000) == .accepted)
        #expect(pacer.stats.framesDroppedQueueFull == 1 && pacer.stats.framesDroppedAwaitingRefresh == 2
                && pacer.stats.framesSuperseded == 1)
    }

    /// Frames after a big keyframe wait for it instead of being refused (its bytes don't count), and a refresh frame
    /// keeps the rest of a keyframe already going out.
    @Test func aKeyframeGoingOutIsKept() {
        let pacer = Pacer(pacingRate: 4_000_000, maxVideoQueueDelay: 25_000)
        pacer.enqueueFrame(Array(repeating: Self.piece(), count: 30), frameID: 1, refresh: true, expires: .max, now: 0)
        #expect(pacer.poll(now: 0).count == 3)
        #expect(pacer.backlogDelay == 0)
        #expect(pacer.admitFrame(refresh: false, now: 1_000) == .accepted)
        pacer.enqueueFrame(Array(repeating: Self.piece(2), count: 2), frameID: 2, refresh: false, expires: .max, now: 1_000)
        #expect(pacer.admitFrame(refresh: true, now: 2_000) == .accepted)
        #expect(pacer.stats.framesSuperseded == 1 && pacer.queuedCount(.video) == 27)
    }

    /// While the network holds more than the congestion window no new frame is taken, a refresh frame neither; the
    /// frame already going out finishes, and once there's room again the next frame must be a refresh frame.
    @Test func aFullCongestionWindowRefusesNewFramesButLetsTheCurrentOneFinish() {
        let pacer = Pacer(pacingRate: 10_000_000, maxVideoQueueDelay: 1_000_000)
        pacer.enqueueFrame(Array(repeating: Self.piece(1), count: 12), frameID: 1, refresh: false, expires: .max, now: 0)
        #expect(pacer.poll(now: 0).count == 6)
        pacer.windowOpen = false
        #expect(pacer.admitFrame(refresh: true, now: 1_000) == .dropped(.congested), "not even a refresh frame")
        #expect(pacer.admitFrame(refresh: false, now: 1_000) == .dropped(.congested))
        pacer.enqueue(Self.sound, priority: .audio, now: 1_000)
        let rest = Self.drain(pacer, count: 7, from: 1_000)
        #expect(rest.first?.item.priority == .audio && rest.dropFirst().allSatisfy { $0.item.frameID == 1 } && rest.count == 7,
                "sound, then the rest of frame 1")
        pacer.windowOpen = true
        #expect(pacer.admitFrame(refresh: false, now: 30_000) == .dropped(.awaitingRefresh))
        #expect(pacer.admitFrame(refresh: true, now: 30_000) == .accepted)
        #expect(pacer.stats.framesDroppedCongested == 2)
    }

    @Test func piecesPastTheirDeadlineAreNotSent() {
        let pacer = Pacer(pacingRate: 10_000_000, maxVideoQueueDelay: 1_000_000)
        pacer.enqueue(Self.piece(1), priority: .retransmission, now: 0, frameID: 1, expires: 10_000)
        pacer.enqueue(Self.piece(2), priority: .video, now: 0, frameID: 2, expires: 100_000)
        let sent = pacer.poll(now: 20_000)
        #expect(sent.map(\.frameID) == [2] && pacer.stats.expired == 1)
    }

    @Test func aProbeGoesAtItsOwnRate() {
        let pacer = Pacer(pacingRate: 1_000_000, maxVideoQueueDelay: 25_000)
        pacer.startProbe(ProbeCluster(id: 9, bitrate: 6_000_000), now: 0)
        var sent: [(time: Int64, item: Pacer.Item)] = []
        var now: Int64 = 0
        while pacer.isProbing, sent.count < 100 {
            sent += pacer.poll(now: now).map { (now, $0) }
            now = max(pacer.nextSendTime(now: now) ?? now + 1, now + 1)
        }
        #expect(sent.count == 10, "11,250 bytes in 1,200-byte packets")
        #expect(sent.allSatisfy { $0.item.probeCluster == 9 && $0.item.size == 1200 })
        #expect(zip(sent.dropFirst(), sent).allSatisfy { $0.time - $1.time == 1_600 }, "1,200 bytes per 1.6 ms is 6 Mbit/s")
    }
}
