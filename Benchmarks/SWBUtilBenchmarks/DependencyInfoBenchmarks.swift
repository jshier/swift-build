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
import struct SWBUtil.DependencyInfo

private func makeDependencyInfo() -> DependencyInfo {
    let coolStrings = Array(repeating: "Some cool string that goes here Some cool string that goes here Some cool string that goes here Some cool string that goes here Some cool string that goes here", count: 10000)
    return DependencyInfo(version: "cool", inputs: coolStrings, missing: coolStrings, outputs: coolStrings)
}

func dependencyInfoBenchmarks() {
    Benchmark.withFixture("DependencyInfo.performance_Normalize") {
        makeDependencyInfo()
    } _: { benchmark, info in
        blackHole(info.normalized())
    }

    Benchmark.withFixture("DependencyInfo.performance_Encoding") {
        makeDependencyInfo()
    } _: { benchmark, info in
        blackHole(try info.asBytes())
    }

    Benchmark.withFixture("DependencyInfo.performance_Decoding") {
        try makeDependencyInfo().asBytes()
    } _: { benchmark, bytes in
        blackHole(try DependencyInfo(bytes: bytes))
    }
}
