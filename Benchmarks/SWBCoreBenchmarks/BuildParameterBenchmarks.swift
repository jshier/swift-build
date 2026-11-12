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
import SWBCore
import SWBProtocol
import SWBTestSupport
import SWBUtil

/// The arguments of build parameters that set every property.
private struct FullBuildParametersArguments {
    let action = BuildAction.build
    let configuration = "Debug"
    let activeRunDestination = RunDestinationInfo(
        platform: "macosx",
        sdk: "macosx12.3",
        sdkVariant: "macos",
        targetArchitecture: "arm64",
        supportedArchitectures: ["arm64", "x86_64"],
        disableOnlyActiveArch: false
    )
    let activeArchitecture = "arm64"
    let overrides = [
        "ENABLE_PREVIEWS": "NO",
        "ONLY_ACTIVE_ARCH": "YES",
    ]
    let commandLineConfigOverridesPath: Path? = nil
    let environmentConfigOverridesPath: Path? = nil
    let toolchainOverride: String? = nil
    let arena = ArenaInfo.indexBuildArena(derivedDataRoot: Path("/Users/username/Library/Developer/Xcode/DerivedData"))

    func makeBuildParameters() -> BuildParameters {
        BuildParameters(
            action: action,
            configuration: configuration,
            activeRunDestination: activeRunDestination,
            activeArchitecture: activeArchitecture,
            overrides: overrides,
            commandLineOverrides: overrides,
            commandLineConfigOverridesPath: commandLineConfigOverridesPath,
            commandLineConfigOverrides: overrides,
            environmentConfigOverridesPath: environmentConfigOverridesPath,
            environmentConfigOverrides: overrides,
            toolchainOverride: toolchainOverride,
            arena: arena
        )
    }
}

func buildParameterBenchmarks() {
    Benchmark.withFixture("BuildParameter.init_X50_000") {
        FullBuildParametersArguments()
    } _: { benchmark, arguments in
        for _ in 0..<50_000 {
            blackHole(arguments.makeBuildParameters())
        }
    }

    Benchmark.withFixture("BuildParameter.hash_X10_000_000") {
        FullBuildParametersArguments().makeBuildParameters()
    } _: { benchmark, parameters in
        var hasher = Hasher()
        for _ in 0..<10_000_000 {
            parameters.hash(into: &hasher)
        }
        blackHole(hasher.finalize())
    }

    Benchmark("BuildParameter.minimalInit_X100_000") { (benchmark: Benchmark) in
        for _ in 0..<100_000 {
            blackHole(BuildParameters(action: .build, configuration: "Debug"))
        }
    }

    Benchmark.withFixture("BuildParameter.minimalHash_X10_000_000") {
        BuildParameters(action: .build, configuration: "Debug")
    } _: { benchmark, parameters in
        var hasher = Hasher()
        for _ in 0..<10_000_000 {
            parameters.hash(into: &hasher)
        }
        blackHole(hasher.finalize())
    }
}
