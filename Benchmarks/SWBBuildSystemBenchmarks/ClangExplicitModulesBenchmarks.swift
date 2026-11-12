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
import Testing

func clangExplicitModulesBenchmarks() {
    #if os(macOS)
        Benchmark.withFixture("ClangExplicitModules.testDynamicTaskScaling", configuration: .swiftBuild(maxIterations: 3)) {
            try await ClangExplicitModulesFixture()
        } _: { (benchmark: Benchmark, fixture: ClangExplicitModulesFixture) in
            try await fixture.tester.checkBuild(runDestination: .macOS, buildCommand: .cleanBuildFolder(style: .regular), body: { _ in })
            benchmark.startMeasurement()
            let results = try await fixture.tester.checkBuild(runDestination: .macOS, persistent: true) { $0 }
            benchmark.stopMeasurement()
            try results.requireNoErrors()
        }

        Benchmark.withFixture("ClangExplicitModules.testScanningIncrementalPerformance", configuration: .swiftBuild(maxIterations: 10)) {
            let fixture = try await ClangExplicitModulesFixture()
            try await fixture.tester.checkBuild(runDestination: .macOS, persistent: true) { results in
                try results.requireNoErrors()
            }
            return fixture
        } _: { (benchmark: Benchmark, fixture: ClangExplicitModulesFixture) in
            try fixture.tester.fs.touch(fixture.sourceRoot.join("file-\(Int.random(in: 0..<ClangExplicitModulesFixture.numSources)).m"))
            benchmark.startMeasurement()
            let results = try await fixture.tester.checkBuild(runDestination: .macOS, persistent: true) { $0 }
            benchmark.stopMeasurement()
            try results.requireNoErrors()
        }
    #endif
}

/// A static library of Objective-C files that include a framework's header, built with explicit Clang modules.
private struct ClangExplicitModulesFixture {
    static let numSources = 500

    let temporaryDirectory: NamedTemporaryDirectory
    let tester: BuildOperationTester
    let sourceRoot: Path

    init() async throws {
        let numSources = Self.numSources
        temporaryDirectory = try NamedTemporaryDirectory()
        let tmpDirPath = temporaryDirectory.path
        let testWorkspace = TestWorkspace(
            "Test",
            sourceRoot: tmpDirPath.join("Test"),
            projects: [
                TestProject(
                    "aProject",
                    groupTree: TestGroup(
                        "Sources",
                        children: (0..<numSources).map { TestFile("file-\($0).m") } + [
                            TestFile("Framework.h"),
                            TestFile("Shared.h"),
                            TestFile("Shared.m"),
                        ]),
                    buildConfigurations: [
                        TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "CLANG_ENABLE_MODULES": "YES",
                                "_EXPERIMENTAL_CLANG_EXPLICIT_MODULES": "YES",
                                "DSTROOT": tmpDirPath.join("dstroot").str,
                            ])
                    ],
                    targets: [
                        TestStandardTarget(
                            "Library",
                            type: .staticLibrary,
                            buildPhases: [
                                TestSourcesBuildPhase((0..<numSources).map { TestBuildFile("file-\($0).m") })
                            ], dependencies: ["Framework"]),
                        TestStandardTarget(
                            "Framework",
                            type: .framework,
                            buildConfigurations: [
                                TestBuildConfiguration(
                                    "Debug",
                                    buildSettings: [
                                        "DEFINES_MODULE": "YES"
                                    ])
                            ],
                            buildPhases: [
                                TestSourcesBuildPhase(["Shared.m"]),
                                TestHeadersBuildPhase([
                                    TestBuildFile("Framework.h", headerVisibility: .public),
                                    TestBuildFile("Shared.h", headerVisibility: .public),
                                ]),
                            ]),
                    ])
            ])

        tester = try await BuildOperationTester(TestingCore().getCore(), testWorkspace, simulated: false)
        sourceRoot = tmpDirPath.join("Test/aProject")

        for i in 0..<numSources {
            try await tester.fs.writeFileContents(sourceRoot.join("file-\(i).m")) { stream in
                stream <<< """
                    #include <Framework/Framework.h>

                    void test\(i)() {
                        NSLog(@"%@", [[Shared alloc] init]);
                        }
                    """
            }
        }

        try await tester.fs.writeFileContents(sourceRoot.join("Framework.h")) { stream in
            stream <<< """
                #include <Framework/Shared.h>
                """
        }

        try await tester.fs.writeFileContents(sourceRoot.join("Shared.h")) { stream in
            stream <<< """
                #include <Foundation/Foundation.h>
                @interface Shared: NSObject {}
                @end

                """
        }

        try await tester.fs.writeFileContents(sourceRoot.join("Shared.m")) { stream in
            stream <<< """
                #include "Shared.h"
                @implementation Shared {}
                @end
                """
        }
    }
}
