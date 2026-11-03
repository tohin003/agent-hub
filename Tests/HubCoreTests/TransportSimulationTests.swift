import Foundation
import Testing

/// The whole transport (packetizer, parity, pacer, resends, rate control, assembler) between the hub's sender and the
/// phone's receiver over emulated paths. Simulated time, so the runs are exact and fast; every measured number is
/// printed with "TRANSPORT-METRIC".
@Suite("Transport over an emulated network")
struct TransportSimulationTests {
    private static func percentile(_ sorted: [Int64], _ fraction: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        return Double(sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * fraction))]) / 1000
    }

    /// A 5 Mbit/s bottleneck with a deep (500 ms) buffer for 10 s, then 2 Mbit/s: the delay-based estimate should
    /// find the capacity within a few seconds without filling the buffer, and back off within about a second.
    @Test func rateControlFindsFiveMegabitsAndBacksOffWhenItDropsToTwo() throws {
        let start: Int64 = 1_000_000
        let drop: Int64 = 11_000_000
        let end: Int64 = 17_000_000
        var forward = EmulatedLink.Config()
        forward.capacity = { $0 < drop ? 5_000_000 : 2_000_000 }
        forward.delay = 20_000
        forward.jitter = 1_000
        forward.queueLimit = 500_000
        var backward = EmulatedLink.Config()
        backward.delay = 20_000
        let simulation = try TransportSimulation(profile: .profile(for: .direct), forward: forward, backward: backward,
                                                 seed: 1)
        simulation.run(until: end)

        let settled = try #require(simulation.firstTarget(after: start) { $0 >= 4_000_000 }) - start
        let utilization = simulation.forward.throughput(from: 4_000_000, to: drop) / 5_000_000
        let steady = simulation.forward.queueDelays(from: 4_000_000, to: drop)
        let backedOff = try #require(simulation.firstTarget(after: drop) { $0 <= 2_200_000 }) - drop
        let lastLongQueue = simulation.forward.queueDelays.last { $0.time >= drop && $0.delay >= 50_000 }?.time ?? drop
        let afterUtilization = simulation.forward.throughput(from: drop + 2_000_000, to: end) / 2_000_000
        let after = simulation.forward.queueDelays(from: drop + 2_000_000, to: end)
        let peak = Double(simulation.forward.queueDelays(from: drop, to: end).last ?? 0) / 1000
        reportMetric(String(format: "5 Mbit/s link: target ≥ 4 Mbit/s after %.2f s; mean target %.2f Mbit/s; delivered "
            + "%.1f%% of capacity (4–11 s); queue delay p50 %.1f ms, p95 %.1f ms, max %.1f ms",
                            Double(settled) / 1e6, simulation.meanTarget(from: 4_000_000, to: drop) / 1e6,
                            utilization * 100, Self.percentile(steady, 0.5), Self.percentile(steady, 0.95),
                            Self.percentile(steady, 1)))
        reportMetric(String(format: "drop to 2 Mbit/s: target ≤ 2.2 Mbit/s after %.2f s; queue under 50 ms again after "
            + "%.2f s (peak %.0f ms); then delivered %.1f%% of capacity, mean target %.2f Mbit/s, queue p50 %.1f ms, "
            + "p95 %.1f ms; frames dropped at the hub %ld, loss drops %ld",
                            Double(backedOff) / 1e6, Double(lastLongQueue - drop) / 1e6, peak, afterUtilization * 100,
                            simulation.meanTarget(from: drop + 2_000_000, to: end) / 1e6, Self.percentile(after, 0.5),
                            Self.percentile(after, 0.95), simulation.dropsAtSender, simulation.forward.stats.queueDrops))
        #expect(settled <= 4_000_000, "near capacity within a few seconds")
        #expect(utilization >= 0.75 && utilization <= 1.0)
        #expect(Self.percentile(steady, 0.5) <= 40, "low queuing delay")
        #expect(Self.percentile(steady, 0.95) <= 120)
        #expect(backedOff <= 1_200_000, "backs off within about a second")
        #expect(afterUtilization >= 0.7)
        #expect(Self.percentile(after, 0.95) <= 150)
    }

    /// Direct path, 40 ms round trip, 3% random loss both ways: resends alone should get ≥ 99% of frames shown by
    /// their deadline.
    @Test func threePercentLossAtFortyMillisecondsIsCoveredByResends() throws {
        var link = EmulatedLink.Config()
        link.capacity = { _ in 20_000_000 }
        link.delay = 20_000
        link.jitter = 2_000
        link.loss = .random(0.03)
        let simulation = try TransportSimulation(profile: .profile(for: .direct), forward: link, backward: link, seed: 3)
        simulation.run(until: 21_000_000)
        let plan = simulation.sender.plan
        let budget = plan.frameDeadline + link.delay
        let summary = simulation.summary(from: 2_000_000, to: 20_500_000, budget: budget)
        let stall = simulation.longestStall(from: 2_000_000, to: 20_500_000)
        reportMetric("3% loss, 40 ms RTT, direct: \(summary); deadline \(plan.frameDeadline / 1000) ms + 20 ms trip; "
            + "longest stall \(stall / 1000) ms; resends sent \(simulation.sender.stats.retransmissions); "
            + "NACK packets \(simulation.receiver.stats.nackPacketsSent); RTT \((simulation.sender.roundTrip ?? 0) / 1000) ms")
        #expect(plan.nack && plan.fec.ratio == 0, "direct Wi-Fi: resends, no parity")
        #expect(summary.onTimeShare >= 0.99)
        #expect(summary.corrupt == 0)
        #expect(summary.withResends > 0)
    }

    /// Peer relay, 60 ms round trip, 10% random loss both ways: parity rebuilds most damaged frames at once, resends
    /// most of the rest.
    @Test func tenPercentLossOnARelayIsCoveredByParityAndResends() throws {
        var link = EmulatedLink.Config()
        link.capacity = { _ in 10_000_000 }
        link.delay = 30_000
        link.jitter = 3_000
        link.loss = .random(0.10)
        let simulation = try TransportSimulation(profile: .profile(for: .peerRelay), forward: link, backward: link, seed: 4)
        simulation.sendsAudio = true
        simulation.run(until: 21_000_000)
        let plan = simulation.sender.plan
        let summary = simulation.summary(from: 2_000_000, to: 20_500_000, budget: plan.frameDeadline + link.delay)
        let stall = simulation.longestStall(from: 2_000_000, to: 20_500_000)
        let sound = Double(simulation.audioFramesReceived) / Double(max(simulation.audioFramesSent, 1))
        reportMetric("10% loss, 60 ms RTT, peer relay: \(summary); parity ratio \(plan.fec.ratio), resends \(plan.nack); "
            + "deadline \(plan.frameDeadline / 1000) ms; longest stall \(stall / 1000) ms; pieces rebuilt "
            + "\(simulation.receiver.stats.fecRecovered); resends \(simulation.sender.stats.retransmissions); sound frames "
            + String(format: "%.1f%% (%ld of them from copies)", sound * 100,
                     simulation.receiver.stats.audioFramesFromRedundancy))
        #expect(plan.fec.ratio >= 0.15, "parity follows the loss")
        #expect(plan.nack)
        #expect(summary.onTimeShare >= 0.95, "most frames saved")
        #expect(summary.withRecovery > 0 && summary.withResends > 0)
        #expect(summary.corrupt == 0)
        #expect(sound >= 0.97, "one copy per packet brings most lost sound back")
    }

    /// Cellular with bursts of loss (3% overall, 3 packets at a time, both ways) on a direct path: light parity plus
    /// resends. A burst of 3 defeats a block's single parity piece and sometimes a resend too, so a few frames (2–5 of
    /// ≈1,100 across seeds and versions) are lost, and each costs a refresh round trip (≈16 frames at 60 fps); the
    /// test holds that to ≥95% on time and a worst freeze under 0.4 s.
    @Test func burstyCellularLoss() throws {
        var link = EmulatedLink.Config()
        link.capacity = { _ in 8_000_000 }
        link.delay = 35_000
        link.jitter = 8_000
        link.loss = .bursty(meanLoss: 0.03, meanBurst: 3)
        let simulation = try TransportSimulation(profile: .profile(for: .direct), network: .cellular, forward: link,
                                                 backward: link, seed: 5)
        simulation.run(until: 21_000_000)
        let plan = simulation.sender.plan
        let summary = simulation.summary(from: 2_000_000, to: 20_500_000, budget: plan.frameDeadline + link.delay)
        let stall = simulation.longestStall(from: 2_000_000, to: 20_500_000)
        reportMetric("bursty 3% loss (bursts of 3), 70 ms RTT, cellular direct: \(summary); parity ratio "
            + "\(plan.fec.ratio); longest stall \(stall / 1000) ms; loss drops \(simulation.forward.stats.lossDrops)")
        #expect(plan.fec.ratio >= 0.1, "cellular gets parity even on a direct path")
        #expect(summary.onTimeShare >= 0.95)
        #expect(stall < 400_000, "no long freeze")
        #expect(summary.corrupt == 0)
    }

    /// DERP: a 300 ms round trip, 5% loss, a 3 Mbit/s path: the profile caps the rate at 2 Mbit/s and 30 fps, and
    /// parity carries the load since resends can't arrive in time.
    @Test func derpLeansOnParityUnderTwoMegabits() throws {
        var link = EmulatedLink.Config()
        link.capacity = { _ in 3_000_000 }
        link.delay = 150_000
        link.jitter = 10_000
        link.loss = .random(0.05)
        let simulation = try TransportSimulation(profile: .profile(for: .derp), forward: link, backward: link, seed: 6)
        simulation.run(until: 21_000_000)
        let plan = simulation.sender.plan
        let summary = simulation.summary(from: 3_000_000, to: 20_000_000, budget: plan.frameDeadline + link.delay)
        let stall = simulation.longestStall(from: 3_000_000, to: 20_000_000)
        let highest = simulation.targets.map(\.bitrate).max() ?? 0
        reportMetric("DERP, 5% loss, 300 ms RTT: \(summary); parity ratio \(plan.fec.ratio), resends \(plan.nack); "
            + "highest target \(highest / 1000) kbit/s; longest stall \(stall / 1000) ms; refresh requests "
            + "\(simulation.refreshRequests)")
        #expect(!plan.nack, "resends can't arrive in time at 300 ms")
        #expect(plan.fec.ratio >= 0.2)
        #expect(highest <= 2_000_000)
        #expect(summary.deliveredShare >= 0.9)
        #expect(summary.corrupt == 0)
    }
}
