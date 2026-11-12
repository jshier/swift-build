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

func utilBenchmarks() {
    Benchmark.withFixture("Util.JSONEncoding") {
        PropertyListItem.plDict([
            "key0": .plString("value0"),
            "key1": .plArray([.plString("value1.0"), .plString("value1.1"), .plString("value1.2")]),
            "key2": .plDict([
                "value2.key0": .plString("value2.value0"),
                "value2.key1": .plString("value2.value1"),
                "value2.key2": .plString("value2.value2"),
                "value2.key3": .plString("value2.value3"),
            ]),
        ])
    } _: { benchmark, itemToEncode in
        for _ in 0..<10000 {
            blackHole(try itemToEncode.asJSONFragment())
        }
    }
}
