//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2025 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import Benchmark
import SWBBenchmarkSupport
import SWBUtil

/// A sequence of `count` random UInt8 numbers drawn from `range`.
private struct RandomUInt8Sequence: Sequence {
    struct RandomUInt8Generator: IteratorProtocol {
        var range: CountableClosedRange<UInt8>
        var count: Int
        mutating func next() -> UInt8? {
            guard count > 0 else { return .none }
            count -= 1
            return UInt8.random(in: range)
        }
    }
    var range: CountableClosedRange<UInt8>
    var count: Int
    func makeIterator() -> RandomUInt8Generator {
        return RandomUInt8Generator(range: range, count: count)
    }
}

func stringBenchmarks() {
    // Creates a buffer containing 256 ASCII characters and then creates strings from it.
    Benchmark.withFixture("String.creationFromASCIIBuffer_X100000") {
        [UInt8](RandomUInt8Sequence(range: 32...127, count: 256))
    } _: { benchmark, buffer in
        for _ in 1...100000 {
            blackHole(buffer.asReadableString())
        }
    }
}
