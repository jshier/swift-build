//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2026 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

package import Benchmark
import Foundation

extension BenchmarkMetric {
    /// The metrics every benchmark reports, so that baselines compare the same measurements everywhere.
    package static var swiftBuild: [BenchmarkMetric] {
        [.wallClock, .cpuTotal, .instructions, .throughput, .mallocCountTotal, .mallocBytesCount, .peakMemoryResident, .peakMemoryResidentDelta]
    }
}

extension Benchmark.Configuration {
    /// The shared metrics, with limits for iterations that take from microseconds to seconds. Results are shown in nanoseconds and unscaled counts, so that small changes show in comparisons.
    ///
    /// `SWB_BENCHMARK_MAX_ITERATIONS` caps the iterations of every benchmark. Allocation counts barely vary between iterations, so a run that only counts allocations needs one.
    package static func swiftBuild(warmupIterations: Int = 1, scalingFactor: BenchmarkScalingFactor = .one, maxDuration: Duration = .seconds(2), maxIterations: Int = 1_000) -> Self {
        let metrics = BenchmarkMetric.swiftBuild
        let iterationLimit = ProcessInfo.processInfo.environment["SWB_BENCHMARK_MAX_ITERATIONS"].flatMap { Int($0) } ?? .max
        return Self(metrics: metrics, timeUnits: .nanoseconds, units: Dictionary(uniqueKeysWithValues: metrics.map { ($0, .count) }), warmupIterations: warmupIterations, scalingFactor: scalingFactor, maxDuration: maxDuration, maxIterations: min(maxIterations, iterationLimit))
    }
}
