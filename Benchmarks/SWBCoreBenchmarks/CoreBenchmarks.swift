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
import SWBCore
import SWBTestSupport

func coreBenchmarks() {
    // Each iteration creates a new core.
    Benchmark("Core.specRegistrationPerf") { (benchmark: Benchmark) in
        try await Core.perfTestSpecRegistration()
    }

    Benchmark("Core.completeSpecLoadingPerf") { (benchmark: Benchmark) in
        try await Core.perfTestSpecLoading()
    }
}
