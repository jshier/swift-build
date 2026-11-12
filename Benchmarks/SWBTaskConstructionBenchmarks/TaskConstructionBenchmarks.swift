//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2025-2026 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import Benchmark
import SWBBenchmarkSupport
import SWBCore
import SWBTaskConstruction
import SWBTestSupport
import SWBUtil
import Testing

#if os(macOS)
    /// 500 frameworks with separate build directories, which each need `CreateBuildDirectory` tasks.
    private final class BuildDirectoriesFixture {
        let temporaryDirectory: NamedTemporaryDirectory
        let tester: TaskConstructionTester

        init() async throws {
            temporaryDirectory = try NamedTemporaryDirectory()
            let tmpDir = temporaryDirectory.path
            let targets: [TestStandardTarget] = (0..<500).map {
                let buildPath = tmpDir.join("build/\($0)")
                return TestStandardTarget(
                    "CoreFoo\($0)", type: .framework,
                    buildConfigurations: [
                        TestBuildConfiguration(
                            "Debug",
                            buildSettings: ["OBJROOT": buildPath.str, "SYMROOT": buildPath.str, "DSTROOT": buildPath.str])
                    ],
                    buildPhases: [TestSourcesBuildPhase(["foo.c"])], dependencies: ["OtherFramework"])
            }

            let testWorkspace = TestWorkspace(
                "Test",
                sourceRoot: tmpDir.join("Test"),
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup("Sources", children: [TestFile("foo.c")]),
                        buildConfigurations: [
                            TestBuildConfiguration(
                                "Debug",
                                buildSettings: [
                                    "PRODUCT_NAME": "$(TARGET_NAME)",
                                    "GENERATE_INFOPLIST_FILE": "YES",
                                    "USE_HEADERMAP": "NO",
                                ])
                        ],
                        targets: [TestAggregateTarget("all", dependencies: targets.map(\.name))] + targets)
                ]
            )
            tester = try await TaskConstructionTester(TestingCore().getCore(), testWorkspace)
        }
    }
#endif

func taskConstructionBenchmarks() {
    #if os(macOS)
        // Regression test for rdar://83518445. Each iteration takes seconds, and plans with a new workspace context, so
        // there's no warm-up iteration, to fit two measured iterations in the time limit.
        Benchmark.withFixture("TaskConstruction.createBuildDirectoryTaskGenerationWith500Targets", configuration: .swiftBuild(warmupIterations: 0, maxDuration: .seconds(10), maxIterations: 2)) {
            try await BuildDirectoriesFixture()
        } _: { benchmark, fixture in
            await fixture.tester.checkBuild(runDestination: .macOS, checkTaskGraphIntegrity: false) { results in
                blackHole(results)
            }
        }
    #endif
}
