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

func dependencyValidatorBenchmarks() {
    #if os(macOS)
        for on in [true, false] {
            Benchmark.withFixture("DependencyValidator.dependencyValidatorBuildOperationPerf.\(on)", configuration: .swiftBuild(warmupIterations: 0, maxIterations: 2)) {
                try await DependencyValidatorFixture(on: on)
            } _: { (benchmark: Benchmark, fixture: DependencyValidatorFixture) in
                // Each iteration uses a new tester, so that it doesn't reuse the previous iteration's build description.
                let tester = try await BuildOperationTester(fixture.core, fixture.testWorkspace, simulated: false)
                let parameters = BuildParameters(action: .build, configuration: "Debug")
                let buildRequest = BuildRequest(parameters: parameters, buildTargets: tester.workspace.allTargets.map { BuildRequest.BuildTargetInfo(parameters: parameters, target: $0) }, dependencyScope: .workspace, continueBuildingAfterErrors: true, useParallelTargets: false, useImplicitDependencies: true, useDryRun: false)

                benchmark.startMeasurement()
                let results = try await tester.checkBuild(parameters: parameters, runDestination: .macOS, buildRequest: buildRequest) { $0 }
                benchmark.stopMeasurement()
                try results.requireNoErrors()
            }
        }
    #endif
}

/// Ten frameworks of 100 Swift files each, with dependency validation on or off.
private struct DependencyValidatorFixture {
    let temporaryDirectory: NamedTemporaryDirectory
    let core: Core
    let testWorkspace: TestWorkspace

    init(on: Bool) async throws {
        temporaryDirectory = try NamedTemporaryDirectory()
        let targets = (0..<10).map { i in
            TestStandardTarget(
                "Target_\(i)",
                type: .framework,
                buildConfigurations: [
                    TestBuildConfiguration(
                        "Debug",
                        buildSettings: [
                            "CODE_SIGNING_ALLOWED": "NO",
                            "DISABLE_MANUAL_TARGET_ORDER_BUILD_WARNING": "YES",
                            "PRODUCT_NAME": "$(TARGET_NAME)",
                            "SWIFT_VERSION": "5",
                            "SWIFT_COMPILATION_MODE": "wholemodule",
                            "SWIFT_ENABLE_EXPLICIT_MODULES": "NO",
                            "VALIDATE_DEPENDENCIES": on ? "YES" : "NO",
                        ])
                ],
                buildPhases: [
                    TestSourcesBuildPhase((0..<100).map { i in TestBuildFile("File\(i).swift") })
                ]
            )
        }

        testWorkspace = TestWorkspace(
            "Workspace",
            sourceRoot: temporaryDirectory.path,
            projects: [
                TestProject(
                    "aProject",
                    groupTree: TestGroup("SomeFiles", children: [] + (0..<100).map { i in TestFile("File\(i).swift", sourceTree: .buildSetting("SRCROOT")) }),
                    targets: targets
                )
            ])
        core = try await TestingCore().getCore()

        let SRCROOT = testWorkspace.sourceRoot.join("aProject")
        for i in (0..<100) {
            try await localFS.writeFileContents(SRCROOT.join("File\(i).swift")) { contents in
                contents <<< "import Foundation\n"
            }
        }
    }
}
