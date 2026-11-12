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

import struct Foundation.Data

import Benchmark
import SWBBenchmarkSupport
import SWBUtil

private struct Thing {
    var value: String
    init(_ value: String) { self.value = value }
}

func outputByteStreamBenchmarks() {
    Benchmark.withFixture("OutputByteStream.test1MBOf16ByteArrays_X100") {
        [UInt8](repeating: 0, count: 1 << 4)
    } _: { benchmark, bytes16 in
        for _ in 0..<100 {
            let stream = OutputByteStream()
            for _ in 0..<(1 << 16) {
                stream <<< bytes16
            }
            blackHole(stream)
        }
    }

    Benchmark.withFixture("OutputByteStream.test1MBOf1KByteArrays_X1000") {
        [UInt8](repeating: 0, count: 1 << 10)
    } _: { benchmark, bytes1k in
        for _ in 0..<1000 {
            let stream = OutputByteStream()
            for _ in 0..<(1 << 10) {
                stream <<< bytes1k
            }
            blackHole(stream)
        }
    }

    Benchmark.withFixture("OutputByteStream.test1MBOf1KByteData_X1000") {
        Data([UInt8](repeating: 0, count: 1 << 10))
    } _: { benchmark, bytes1k in
        for _ in 0..<1000 {
            let stream = OutputByteStream()
            for _ in 0..<(1 << 10) {
                stream <<< bytes1k
            }
            blackHole(stream)
        }
    }

    Benchmark.withFixture("OutputByteStream.test1MBOf16ByteStrings_X10") {
        String(repeating: "X", count: 1 << 4)
    } _: { benchmark, string16 in
        for _ in 0..<10 {
            let stream = OutputByteStream()
            for _ in 0..<(1 << 16) {
                stream <<< string16
            }
            blackHole(stream)
        }
    }

    Benchmark.withFixture("OutputByteStream.test1MBOf1KByteStrings_X100") {
        String(repeating: "X", count: 1 << 10)
    } _: { benchmark, bytes1k in
        for _ in 0..<100 {
            let stream = OutputByteStream()
            for _ in 0..<(1 << 10) {
                stream <<< bytes1k
            }
            blackHole(stream)
        }
    }

    Benchmark.withFixture("OutputByteStream.test1MBOfJSONEncoded16ByteStrings_X10") {
        String(repeating: "X", count: 1 << 4)
    } _: { benchmark, string16 in
        for _ in 0..<10 {
            let stream = OutputByteStream()
            for _ in 0..<(1 << 16) {
                stream.writeJSONEscaped(string16)
            }
            blackHole(stream)
        }
    }

    Benchmark.withFixture("OutputByteStream.formattedJSONOutput") {
        let listOfStrings: [String] = (0..<10).map { "This is the number: \($0)!\n" }
        return (listOfStrings, listOfStrings.map(Thing.init))
    } _: { benchmark, lists in
        let (listOfStrings, listOfThings) = lists
        for _ in 0..<10 {
            let stream = OutputByteStream()
            for _ in 0..<(1 << 10) {
                for string in listOfStrings {
                    stream <<< Format.asJSON(string)
                }
                stream <<< Format.asJSON(listOfStrings)
                stream <<< Format.asJSON(listOfThings, transform: { $0.value })
            }
            blackHole(stream)
        }
    }
}
