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

func byteStringBenchmarks() {
    Benchmark.withFixture("ByteString.initialization") {
        (0..<10).map { "This is the number: \($0)!\n" }
    } _: { benchmark, listOfStrings in
        var count = 0
        for _ in 0..<10000 {
            for string in listOfStrings {
                let bs = ByteString(encodingAsUTF8: string)
                count += bs.count
            }
        }
        blackHole(count)
    }
}
