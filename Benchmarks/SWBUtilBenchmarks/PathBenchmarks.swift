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

func pathBenchmarks() {
    let N = 100000

    Benchmark.withFixture("Path.splitPerf_X100000") {
        Path("/hello/little/world")
    } _: { benchmark, path in
        var lengths = 0
        for _ in 0..<N {
            let result = path.split()
            lengths = lengths &+ result.0.str.utf8.count &+ 1 &+ result.1.utf8.count
        }
        blackHole(lengths)
    }

    Benchmark.withFixture("Path.dirnamePerf_X100000") {
        Path("/hello/little/world")
    } _: { benchmark, path in
        var lengths = 0
        for _ in 0..<N {
            let result = path.dirname
            lengths = lengths &+ result.str.utf8.count
        }
        blackHole(lengths)
    }

    Benchmark.withFixture("Path.basenamePerf_X100000") {
        Path("/hello/little/world")
    } _: { benchmark, path in
        var lengths = 0
        for _ in 0..<N {
            let result = path.basename
            lengths = lengths &+ result.utf8.count
        }
        blackHole(lengths)
    }

    Benchmark.withFixture("Path.basenameWithoutSuffixPerf_X100000") {
        Path("/hello/little/world.ext")
    } _: { benchmark, path in
        var lengths = 0
        for _ in 0..<N {
            let result = path.basenameWithoutSuffix
            lengths = lengths &+ result.utf8.count
        }
        blackHole(lengths)
    }

    Benchmark.withFixture("Path.withoutSuffixPerf_X100000") {
        Path("/hello/little/world.ext")
    } _: { benchmark, path in
        var lengths = 0
        for _ in 0..<N {
            let result = path.withoutSuffix
            lengths = lengths &+ result.utf8.count
        }
        blackHole(lengths)
    }

    Benchmark.withFixture("Path.fileSuffixPerf_X100000") {
        Path("/hello/little/world.ext")
    } _: { benchmark, path in
        var lengths = 0
        for _ in 0..<N {
            let result = path.fileSuffix
            lengths = lengths &+ result.utf8.count
        }
        blackHole(lengths)
    }

    Benchmark.withFixture("Path.fileExtensionPerf_X100000") {
        Path("/hello/little/world.ext")
    } _: { benchmark, path in
        var lengths = 0
        for _ in 0..<N {
            let result = path.fileExtension
            lengths = lengths &+ result.utf8.count
        }
        blackHole(lengths)
    }

    Benchmark.withFixture("Path.normalizePerf_X100000") {
        Path("/hello/little/../tiny/world")
    } _: { benchmark, path in
        var lengths = 0
        for _ in 0..<N {
            let result = path.normalize()
            lengths = lengths &+ result.str.utf8.count
        }
        blackHole(lengths)
    }

    Benchmark.withFixture("Path.joinPerf_X100000") {
        (Path("/hello/little"), Path("world"))
    } _: { benchmark, paths in
        let (path, path2) = paths
        var lengths = 0
        for _ in 0..<N {
            let result = path.join(path2)
            lengths = lengths &+ result.str.utf8.count
        }
        blackHole(lengths)
    }
}
