import Foundation
import Testing

/// Reed–Solomon over GF(2^8): any K of K + M shards rebuild the data, M + 1 losses fail cleanly.
@Suite("Reed–Solomon")
struct ReedSolomonTests {
    @Test func fieldArithmetic() throws {
        for a in 1...255 {
            let value = UInt8(a)
            #expect(GF256.multiply(value, GF256.inverse(value)) == 1, "\(a) × its inverse")
            #expect(GF256.multiply(value, 1) == value && GF256.multiply(value, 0) == 0)
        }
        var random = SeededGenerator(seed: 11)
        for _ in 0..<2000 {
            let a = UInt8(truncatingIfNeeded: random.next())
            let b = UInt8(truncatingIfNeeded: random.next())
            let c = UInt8(truncatingIfNeeded: random.next())
            #expect(GF256.multiply(a, b) == GF256.multiply(b, a))
            #expect(GF256.multiply(a, b ^ c) == GF256.multiply(a, b) ^ GF256.multiply(a, c), "distributes over XOR")
            #expect(GF256.multiply(GF256.multiply(a, b), c) == GF256.multiply(a, GF256.multiply(b, c)))
        }
        // 2 generates the whole multiplicative group.
        var seen = Set<UInt8>()
        var power: UInt8 = 1
        for _ in 0..<255 {
            seen.insert(power)
            power = GF256.multiply(power, 2)
        }
        #expect(seen.count == 255 && power == 1)
    }

    @Test func inversionGivesTheIdentity() throws {
        for size in [1, 2, 5, 16, 40] {
            // A square Cauchy matrix: always invertible.
            let rows = (0..<size).map { row in (0..<size).map { column in GF256.inverse(UInt8(size + row) ^ UInt8(column)) } }
            let inverse = try #require(GF256.invert(rows))
            for i in 0..<size {
                for j in 0..<size {
                    var sum: UInt8 = 0
                    for k in 0..<size { sum ^= GF256.multiply(rows[i][k], inverse[k][j]) }
                    #expect(sum == (i == j ? 1 : 0))
                }
            }
        }
        #expect(GF256.invert([[1, 2], [2, 4]]) == nil, "a singular matrix")
    }

    /// Every way of losing exactly M shards (all of them up to 4,000 patterns, else 400 random ones) is rebuilt; one
    /// more loss fails.
    @Test(arguments: [(1, 1), (2, 1), (3, 2), (4, 2), (5, 1), (6, 3), (8, 4), (10, 3), (16, 4), (20, 4), (32, 8), (12, 12)])
    func recoversAnyMLosses(dataShards: Int, parityShards: Int) throws {
        let code = try #require(ReedSolomon(dataShards: dataShards, parityShards: parityShards))
        var random = SeededGenerator(seed: UInt64(dataShards * 100 + parityShards))
        let length = 1 + Int(random.next() % 1200)
        let data = (0..<dataShards).map { _ in (0..<length).map { _ in UInt8(truncatingIfNeeded: random.next()) } }
        let parity = try #require(code.encode(data))
        #expect(parity.count == parityShards && parity.allSatisfy { $0.count == length })
        let all = data + parity
        let total = dataShards + parityShards
        let patterns = Self.patterns(choose: parityShards, from: total, limit: 4000, random: &random)
        for lost in patterns {
            var shards: [[UInt8]?] = all
            for index in lost { shards[index] = nil }
            #expect(code.reconstruct(shards) == data, "lost \(lost)")
            // One more loss is one too many.
            if let extra = (0..<total).first(where: { !lost.contains($0) }) {
                shards[extra] = nil
                #expect(code.reconstruct(shards) == nil)
            }
        }
        reportMetric("Reed–Solomon K=\(dataShards) M=\(parityShards), \(length)-byte shards: \(patterns.count) loss patterns rebuilt")
    }

    @Test func refusesWhatDoesntFit() {
        #expect(ReedSolomon(dataShards: 0, parityShards: 1) == nil)
        #expect(ReedSolomon(dataShards: 200, parityShards: 57) == nil)
        let code = ReedSolomon(dataShards: 2, parityShards: 1)
        #expect(code?.encode([[1, 2], [3]]) == nil, "shards of different lengths")
        #expect(code?.reconstruct([[1, 2], nil]) == nil, "the wrong number of shards")
    }

    /// Encoding and rebuilding speed for the largest blocks a frame uses (debug build, so a lower bound).
    @Test func codingThroughput() throws {
        let code = try #require(ReedSolomon(dataShards: 32, parityShards: 8))
        var random = SeededGenerator(seed: 13)
        let data = (0..<32).map { _ in (0..<VideoFragment.maxPayloadSize).map { _ in UInt8(truncatingIfNeeded: random.next()) } }
        let rounds = 20
        let encodeStart = ContinuousClock.now
        var parity: [[UInt8]] = []
        for _ in 0..<rounds { parity = try #require(code.encode(data)) }
        let encodeTime = ContinuousClock.now - encodeStart
        var shards: [[UInt8]?] = data + parity
        for index in [0, 3, 7, 11, 15, 19, 23, 31] { shards[index] = nil }
        let decodeStart = ContinuousClock.now
        for _ in 0..<rounds { #expect(code.reconstruct(shards) == data) }
        let decodeTime = ContinuousClock.now - decodeStart
        let megabytes = Double(32 * VideoFragment.maxPayloadSize * rounds) / 1e6
        let encodeRate = megabytes / (encodeTime / .seconds(1))
        let decodeRate = megabytes / (decodeTime / .seconds(1))
        reportMetric(String(format: "Reed–Solomon 32+8, 1,147-byte shards: encode %.1f MB/s, rebuild 8 lost %.1f MB/s (debug build)",
                            encodeRate, decodeRate))
        #expect(encodeRate > 0.5, "unoptimized; the release build measures far faster (see the report)")
    }

    /// Exhaustive combinations when there are few, else random ones.
    static func patterns(choose count: Int, from total: Int, limit: Int, random: inout SeededGenerator) -> [[Int]] {
        var combinations = 1.0
        for index in 0..<count { combinations = combinations * Double(total - index) / Double(index + 1) }
        if combinations <= Double(limit) {
            var result: [[Int]] = []
            func build(_ start: Int, _ current: [Int]) {
                if current.count == count {
                    result.append(current)
                    return
                }
                guard start < total else { return }
                for next in start..<total { build(next + 1, current + [next]) }
            }
            build(0, [])
            return result
        }
        return (0..<400).map { _ in
            var chosen = Set<Int>()
            while chosen.count < count { chosen.insert(Int(random.next() % UInt64(total))) }
            return chosen.sorted()
        }
    }
}
