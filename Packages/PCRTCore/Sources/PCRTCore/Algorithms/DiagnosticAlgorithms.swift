import Foundation

public enum DiagnosticAlgorithms {
    public static func primeCount(upTo limit: Int) -> Int {
        guard limit >= 2 else { return 0 }
        var sieve = [Bool](repeating: true, count: limit + 1)
        sieve[0] = false
        sieve[1] = false
        let root = Int(Double(limit).squareRoot())
        if root >= 2 {
            for candidate in 2...root where sieve[candidate] {
                var multiple = candidate * candidate
                while multiple <= limit {
                    sieve[multiple] = false
                    multiple += candidate
                }
            }
        }
        return sieve.reduce(0) { $0 + ($1 ? 1 : 0) }
    }

    public static func sumOfSquares(_ count: UInt64) -> UInt64 {
        guard count > 0 else { return 0 }
        return count &* (count &+ 1) &* (2 &* count &+ 1) / 6
    }

    public static func deterministicBlock(blockIndex: Int, byteCount: Int) -> Data {
        var state = UInt64(blockIndex + 1) &* 0x9e3779b97f4a7c15
        var data = Data(count: byteCount)
        data.withUnsafeMutableBytes { rawBuffer in
            guard let bytes = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return }
            for index in 0..<byteCount {
                state ^= state << 13
                state ^= state >> 7
                state ^= state << 17
                bytes[index] = UInt8(truncatingIfNeeded: state >> 56)
            }
        }
        return data
    }

    public static func driveSampleOffsets(size: UInt64, blockSize: UInt64 = 1_048_576) -> (offsets: [UInt64], generatedCount: Int) {
        guard blockSize > 0 else { return ([], 0) }
        guard size > blockSize else { return ([0], 1) }
        let maxOffset = size - blockSize
        func align(_ value: UInt64) -> UInt64 { (value / 4096) * 4096 }
        var generated: [UInt64] = []
        for index in 0..<24 {
            generated.append(align(UInt64(index) * maxOffset / 23))
        }
        var seed = size ^ 0x9e3779b97f4a7c15
        for _ in 0..<24 {
            seed ^= seed << 13
            seed ^= seed >> 7
            seed ^= seed << 17
            generated.append(align(seed % (maxOffset + 1)))
        }
        generated.append(contentsOf: [0, align(maxOffset), align(maxOffset / 100), align(maxOffset * 99 / 100)])

        var seen = Set<UInt64>()
        var unique: [UInt64] = []
        for generatedOffset in generated {
            let offset = min(generatedOffset, align(maxOffset))
            if seen.insert(offset).inserted {
                unique.append(offset)
            }
        }
        return (unique, generated.count)
    }

    public static let memoryPatternNames = [
        "Bit low",
        "Bit high",
        "Checkerboard",
        "Inverse checkerboard",
        "Walking ones",
        "Walking zeros",
        "Address-as-data",
        "Modulo20",
        "Moving inversion",
        "Block move",
        "Seeded random"
    ]
}
