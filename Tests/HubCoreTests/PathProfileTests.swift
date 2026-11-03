import Foundation
import Testing

/// Which path Tailscale uses to the phone, read from `tailscale status --json`, and the profile table it selects.
@Suite("Path profiles")
struct PathProfileTests {
    /// A status in the shape Tailscale 1.104 prints (fields as on this Mac; addresses made up).
    static func status(peer: String) -> Data {
        Data("""
        {"Version":"1.104.4","BackendState":"Running","TailscaleIPs":["100.66.1.2","fd7a:115c:a1e0::1901:1"],
         "Self":{"HostName":"Mac","TailscaleIPs":["100.66.1.2","fd7a:115c:a1e0::1901:1"],"CurAddr":"","Relay":"nyc",
                 "PeerRelay":"","Active":false,"Online":true},
         "Peer":{"nodekey:aaaa":{"HostName":"localhost","OS":"iOS","TailscaleIPs":["100.101.102.103","fd7a:115c:a1e0::ab12:4567"],
                 \(peer)},
                 "nodekey:bbbb":{"HostName":"other","OS":"linux","TailscaleIPs":["100.70.0.9"],"CurAddr":"198.51.100.4:41641",
                 "Relay":"fra","PeerRelay":"","Active":true}},
         "User":{}}
        """.utf8)
    }

    @Test func classifiesTheDirectRelayedAndDERPPaths() {
        let phone = "100.101.102.103"
        let direct = Self.status(peer: #""CurAddr":"203.0.113.7:41641","Relay":"nyc","PeerRelay":"","Active":true"#)
        #expect(TailscalePathClassifier.classify(statusJSON: direct, peerAddress: phone)
                == TailscalePeerPath(kind: .direct, via: "203.0.113.7:41641"))
        let relayed = Self.status(peer: #""CurAddr":"","Relay":"nyc","PeerRelay":"100.70.0.9:40000:vni:12","Active":true"#)
        #expect(TailscalePathClassifier.classify(statusJSON: relayed, peerAddress: phone)
                == TailscalePeerPath(kind: .peerRelay, via: "100.70.0.9:40000:vni:12"))
        let derp = Self.status(peer: #""CurAddr":"","Relay":"nyc","PeerRelay":"","Active":true"#)
        #expect(TailscalePathClassifier.classify(statusJSON: derp, peerAddress: phone) == TailscalePeerPath(kind: .derp, via: "nyc"))
        // Idle: Relay is only the home region, not where traffic goes.
        let idle = Self.status(peer: #""CurAddr":"","Relay":"nyc","PeerRelay":"","Active":false"#)
        #expect(TailscalePathClassifier.classify(statusJSON: idle, peerAddress: phone).kind == .unknown)
        // By IPv6 written differently, and a peer that isn't there.
        #expect(TailscalePathClassifier.classify(statusJSON: derp, peerAddress: "FD7A:115C:A1E0:0:0:0:AB12:4567").kind == .derp)
        #expect(TailscalePathClassifier.classify(statusJSON: derp, peerAddress: "100.101.102.104").kind == .unknown)
        #expect(TailscalePathClassifier.classify(statusJSON: Data("{".utf8), peerAddress: phone).kind == .unknown)
        #expect(TailscalePathClassifier.classify(statusJSON: derp, peerAddress: "not an address").kind == .unknown)
    }

    @Test func theTableMatchesThePlan() {
        for path in PathKind.allCases { #expect(PathProfile.table[path]?.path == path, "a row for \(path)") }
        let direct = PathProfile.profile(for: .direct)
        let relay = PathProfile.profile(for: .peerRelay)
        let derp = PathProfile.profile(for: .derp)
        #expect(direct.maxBitrate == 10_000_000 && direct.maxFramesPerSecond == 60 && direct.fecRatio == 0)
        #expect(relay.maxBitrate <= 5_000_000 && relay.fecRatio > 0 && relay.fecRatio < derp.fecRatio)
        #expect(derp.maxBitrate <= 2_000_000 && derp.maxFramesPerSecond <= 30 && derp.fecRatio == 0.2)
        #expect(derp.frameDeadlineMaxMs > relay.frameDeadlineMaxMs && derp.audioBufferMs > relay.audioBufferMs
                && relay.audioBufferMs > direct.audioBufferMs, "bigger buffers on slower paths")
        #expect([direct, relay, derp].allSatisfy { (20...35).contains($0.videoQueueMs) }, "20–35 ms of picture backlog")
        #expect([direct, relay, derp].allSatisfy { $0.minBitrate < $0.startBitrate && $0.startBitrate <= $0.maxBitrate })
        let json = try? JSONValue(encoding: derp).decode(PathProfile.self)
        #expect(json == derp, "the profile travels in the negotiation's answer")
    }

    @Test func onlyTailnetAndLoopbackAddressesMaySend() {
        for address in ["100.64.0.1", "100.127.255.255", "100.101.102.103", "fd7a:115c:a1e0::ab12:4567", "FD7A:115C:A1E0:1::1"] {
            #expect(TailnetAddress.isTailnet(address), "\(address)")
        }
        for address in ["100.63.255.255", "100.128.0.1", "192.168.1.5", "10.0.0.1", "fd7a:115c:a1e1::1", "fe80::1", "", "example.com"] {
            #expect(!TailnetAddress.isTailnet(address), "\(address)")
        }
        #expect(TailnetAddress.isLoopback("127.0.0.1") && TailnetAddress.isLoopback("::1") && !TailnetAddress.isLoopback("::2"))
        #expect(UDPMediaServer.AddressPolicy.tailnetOrLoopback.allows("127.0.0.1"))
        #expect(!UDPMediaServer.AddressPolicy.tailnet.allows("127.0.0.1"))
        #expect(UDPMediaServer.AddressPolicy.tailnet.allows("100.100.100.100"))
    }

    /// The real `tailscale status --json` on this Mac, when Tailscale is installed: read-only, and it only checks that
    /// every peer classifies (kinds are printed, names and addresses aren't).
    @Test func readsThisMacsTailscaleStatus() throws {
        guard let cli = TailscalePathMonitor.findCLI() else {
            reportMetric("tailscale CLI not installed: live status not read")
            return
        }
        let start = ContinuousClock.now
        guard let json = TailscalePathMonitor.status(cli: cli) else {
            reportMetric("tailscale status --json failed (Tailscale stopped?)")
            return
        }
        let elapsed = ContinuousClock.now - start
        let object = try #require(try JSONSerialization.jsonObject(with: json) as? [String: Any])
        let peers = (object["Peer"] as? [String: [String: Any]]) ?? [:]
        var kinds: [PathKind: Int] = [:]
        for peer in peers.values {
            guard let address = (peer["TailscaleIPs"] as? [String])?.first else { continue }
            kinds[TailscalePathClassifier.classify(statusJSON: json, peerAddress: address).kind, default: 0] += 1
        }
        reportMetric("live tailscale status: \(peers.count) peer(s), paths \(kinds.map { "\($0.key.rawValue)×\($0.value)" }.sorted()); "
            + "the CLI took \(elapsed)")
        #expect(kinds.values.reduce(0, +) == peers.count)
    }
}
