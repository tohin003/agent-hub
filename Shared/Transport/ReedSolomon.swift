import Foundation

/// Arithmetic in GF(2^8) with the polynomial x^8 + x^4 + x^3 + x^2 + 1 (0x11D) and generator 2, by tables: addition
/// is XOR, multiplication one lookup in a 64 KB table.
nonisolated enum GF256 {
    private static let tables: (exp: [UInt8], log: [UInt8]) = {
        var exp = [UInt8](repeating: 0, count: 512)
        var log = [UInt8](repeating: 0, count: 256)
        var value = 1
        for power in 0..<255 {
            exp[power] = UInt8(value)
            log[value] = UInt8(power)
            value <<= 1
            if value & 0x100 != 0 { value ^= 0x11D }
        }
        // A second copy, so exp[log a + log b] needs no modulo.
        for power in 255..<512 { exp[power] = exp[power - 255] }
        return (exp, log)
    }()

    /// a × b at index a << 8 | b.
    static let products: [UInt8] = {
        let (exp, log) = tables
        var table = [UInt8](repeating: 0, count: 65_536)
        for a in 1..<256 {
            for b in 1..<256 { table[a << 8 | b] = exp[Int(log[a]) + Int(log[b])] }
        }
        return table
    }()

    static func multiply(_ a: UInt8, _ b: UInt8) -> UInt8 { products[Int(a) << 8 | Int(b)] }

    /// The multiplicative inverse; 0 has none and maps to 0.
    static func inverse(_ a: UInt8) -> UInt8 {
        guard a != 0 else { return 0 }
        let (exp, log) = tables
        return exp[255 - Int(log[Int(a)])]
    }

    /// out[i] ^= coefficient × input[i], for the first `count` bytes.
    static func multiplyAdd(_ coefficient: UInt8, _ input: UnsafeBufferPointer<UInt8>, into out: UnsafeMutableBufferPointer<UInt8>,
                            count: Int) {
        guard coefficient != 0, count > 0 else { return }
        if coefficient == 1 {
            for index in 0..<count { out[index] ^= input[index] }
            return
        }
        products.withUnsafeBufferPointer { table in
            let row = Int(coefficient) << 8
            for index in 0..<count { out[index] ^= table[row | Int(input[index])] }
        }
    }

    /// The inverse of a square matrix by Gauss–Jordan elimination; nil if it's singular.
    static func invert(_ matrix: [[UInt8]]) -> [[UInt8]]? {
        let size = matrix.count
        guard matrix.allSatisfy({ $0.count == size }) else { return nil }
        var work = matrix
        var inverse = (0..<size).map { row in (0..<size).map { column in UInt8(row == column ? 1 : 0) } }
        for column in 0..<size {
            guard let pivot = (column..<size).first(where: { work[$0][column] != 0 }) else { return nil }
            if pivot != column {
                work.swapAt(pivot, column)
                inverse.swapAt(pivot, column)
            }
            let scale = Self.inverse(work[column][column])
            for index in 0..<size {
                work[column][index] = multiply(work[column][index], scale)
                inverse[column][index] = multiply(inverse[column][index], scale)
            }
            for row in 0..<size where row != column && work[row][column] != 0 {
                let factor = work[row][column]
                for index in 0..<size {
                    work[row][index] ^= multiply(factor, work[column][index])
                    inverse[row][index] ^= multiply(factor, inverse[column][index])
                }
            }
        }
        return inverse
    }
}

/// Systematic Reed–Solomon erasure coding over GF(2^8): K data shards travel as they are, M parity shards are added,
/// and any K of the K + M rebuild the data. The parity rows form a Cauchy matrix (row i, column j: 1 / (x_i + y_j)
/// with x_i = K + i and y_j = j, all distinct), every square submatrix of which is invertible, so any K rows of the
/// whole generator [I; C] are too: the code is MDS for any K + M ≤ 256.
nonisolated public struct ReedSolomon: Sendable {
    public let dataShards: Int
    public let parityShards: Int
    /// M rows of K coefficients.
    private let parityRows: [[UInt8]]

    /// Nil unless 1 ≤ K, 0 ≤ M and K + M ≤ 256.
    public init?(dataShards: Int, parityShards: Int) {
        guard dataShards >= 1, parityShards >= 0, dataShards + parityShards <= 256 else { return nil }
        self.dataShards = dataShards
        self.parityShards = parityShards
        parityRows = (0..<parityShards).map { row in
            (0..<dataShards).map { column in GF256.inverse(UInt8(dataShards + row) ^ UInt8(column)) }
        }
    }

    /// The parity shards for K data shards of one length; nil if the shards don't match the code.
    public func encode(_ data: [[UInt8]]) -> [[UInt8]]? {
        guard data.count == dataShards, let length = data.first?.count,
              data.allSatisfy({ $0.count == length }) else { return nil }
        var parity = [[UInt8]](repeating: [UInt8](repeating: 0, count: length), count: parityShards)
        for row in 0..<parityShards {
            parity[row].withUnsafeMutableBufferPointer { out in
                for column in 0..<dataShards {
                    data[column].withUnsafeBufferPointer { input in
                        GF256.multiplyAdd(parityRows[row][column], input, into: out, count: length)
                    }
                }
            }
        }
        return parity
    }

    /// The K data shards, rebuilt from any K of the K + M (missing ones nil, data first, then parity); nil when fewer
    /// than K are there or they differ in length.
    public func reconstruct(_ shards: [[UInt8]?]) -> [[UInt8]]? {
        guard shards.count == dataShards + parityShards else { return nil }
        let present = shards.indices.filter { shards[$0] != nil }
        guard present.count >= dataShards, let length = present.first.flatMap({ shards[$0]?.count }),
              present.allSatisfy({ shards[$0]?.count == length }) else { return nil }
        let missingData = (0..<dataShards).filter { shards[$0] == nil }
        if missingData.isEmpty { return (0..<dataShards).compactMap { shards[$0] } }
        // K rows of the generator for shards we have (the data ones first, since `present` is in order); their inverse
        // turns those shards back into the data.
        let rows = Array(present.prefix(dataShards))
        let generator = rows.map { row -> [UInt8] in
            row < dataShards ? (0..<dataShards).map { UInt8($0 == row ? 1 : 0) } : parityRows[row - dataShards]
        }
        guard let decode = GF256.invert(generator) else { return nil }
        var result = shards.prefix(dataShards).map { $0 ?? [] }
        for missing in missingData {
            var out = [UInt8](repeating: 0, count: length)
            out.withUnsafeMutableBufferPointer { buffer in
                for (index, row) in rows.enumerated() {
                    shards[row]?.withUnsafeBufferPointer { input in
                        GF256.multiplyAdd(decode[missing][index], input, into: buffer, count: length)
                    }
                }
            }
            result[missing] = out
        }
        return result
    }
}
