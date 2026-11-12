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

func swiftDriverBenchmarks() {
    #if os(macOS)
        // Builds with the integrated Swift driver, cleaning after each build.
        Benchmark.withFixture("SwiftDriver.swiftDriverBuildPerformance", configuration: .swiftBuild(warmupIterations: 0, maxIterations: 1)) {
            try await SwiftDriverBuildFixture()
        } _: { (benchmark: Benchmark, fixture: SwiftDriverBuildFixture) in
            var builds: [BuildOperationTester.BuildResults] = []
            for _ in 0..<SwiftDriverBuildFixture.iterations {
                try await builds.append(fixture.tester.checkBuild(runDestination: .macOS, buildRequest: fixture.buildRequest, serial: true) { $0 })
                try await fixture.tester.checkBuild(runDestination: .macOS, buildCommand: BuildCommand.cleanBuildFolder(style: .regular), body: { _ in })
            }
            benchmark.stopMeasurement()
            for results in builds {
                try results.requireNoErrors()
            }
        }

        Benchmark.withFixture("SwiftDriver.incrementalBuildPerformance", configuration: .swiftBuild(maxIterations: 3)) {
            try await IncrementalBuildFixture()
        } _: { (benchmark: Benchmark, fixture: IncrementalBuildFixture) in
            try localFS.touch(fixture.sourceRoot.join(fixture.filenames.randomElement()!))
            benchmark.startMeasurement()
            let results = try await fixture.tester.checkBuild(runDestination: .macOS, buildRequest: fixture.buildRequest, persistent: true) { $0 }
            benchmark.stopMeasurement()
            try results.requireNoErrors()
        }
    #endif
}

/// Five frameworks of 300 Swift files each.
private struct SwiftDriverBuildFixture {
    static let numSwiftFiles = 300
    static let numTargets = 5
    static let iterations = 2

    let temporaryDirectory: NamedTemporaryDirectory
    let tester: BuildOperationTester
    let buildRequest: BuildRequest

    init() async throws {
        temporaryDirectory = try NamedTemporaryDirectory()
        let targets = (0..<Self.numTargets).map { targetNum -> (any TestTarget) in
            TestStandardTarget(
                "Target\(targetNum)", type: .framework,
                buildPhases: [
                    TestSourcesBuildPhase((0..<Self.numSwiftFiles).map({ TestBuildFile("Target-\(targetNum)-File-\($0).swift") }))
                ],
                provisioningSourceData: [
                    SWBProtocol.ProvisioningSourceData(
                        configurationName: "Debug",
                        provisioningStyle: .manual,
                        bundleIdentifierFromInfoPlist: "$(PRODUCT_BUNDLE_IDENTIFIER)")
                ])
        }

        let testingCore = TestingCore()
        let swiftVersion = try await testingCore.swiftVersion
        let testProject = TestProject(
            "aProject",
            defaultConfigurationName: "Debug",
            groupTree: TestGroup(
                "Root",
                children: (0..<Self.numTargets).flatMap { targetNum in
                    (0..<Self.numSwiftFiles).map { TestFile("Target-\(targetNum)-File-\($0).swift") }
                }),
            buildConfigurations: [
                TestBuildConfiguration(
                    "Debug",
                    buildSettings: [
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "SWIFT_VERSION": swiftVersion,

                        "SWIFT_USE_INTEGRATED_DRIVER": "YES",

                        "DSTROOT": temporaryDirectory.path.join("dstroot").str,
                    ]
                )
            ],
            targets: targets
        )
        let testWorkspace = TestWorkspace(
            "aWorkspace",
            sourceRoot: temporaryDirectory.path.join("Test"),
            projects: [testProject])
        let SRCROOT = testWorkspace.sourceRoot.join("aProject")

        for targetNum in 0..<Self.numTargets {
            for fileNum in 0..<Self.numSwiftFiles {
                try await localFS.writeFileContents(SRCROOT.join("Target-\(targetNum)-File-\(fileNum).swift")) { contents in
                    contents <<< "func foobar\(targetNum)\(fileNum)() {}\n"
                }
            }
        }

        tester = try await BuildOperationTester(testingCore.getCore(), testWorkspace, simulated: false)
        let parameters = BuildParameters(configuration: "Debug")
        buildRequest = BuildRequest(parameters: parameters, buildTargets: tester.workspace.projects[0].targets.map({ BuildRequest.BuildTargetInfo(parameters: parameters, target: $0) }), dependencyScope: .workspace, continueBuildingAfterErrors: true, useParallelTargets: true, useImplicitDependencies: false, useDryRun: false)
    }
}

/// A framework of 1000 Swift files, built once.
private struct IncrementalBuildFixture {
    let temporaryDirectory: NamedTemporaryDirectory
    let filenames: [String]
    let sourceRoot: Path
    let tester: BuildOperationTester
    let buildRequest: BuildRequest

    init() async throws {
        temporaryDirectory = try NamedTemporaryDirectory()
        let testingCore = TestingCore()
        let swiftVersion = try await testingCore.swiftVersion
        filenames = (0..<1000).map { "File-\($0).swift" }
        let testWorkspace = TestWorkspace(
            "aWorkspace",
            sourceRoot: temporaryDirectory.path.join("Test"),
            projects: [
                TestProject(
                    "aProject",
                    defaultConfigurationName: "Debug",
                    groupTree: TestGroup("Root", children: filenames.map { TestFile($0) }),
                    buildConfigurations: [
                        TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "SWIFT_VERSION": swiftVersion,
                                "DSTROOT": temporaryDirectory.path.join("dstroot").str,
                            ]
                        )
                    ],
                    targets: [
                        TestStandardTarget(
                            "Framework", type: .framework,
                            buildPhases: [
                                TestSourcesBuildPhase(filenames.map { TestBuildFile($0) })
                            ])
                    ]
                )
            ])
        sourceRoot = testWorkspace.sourceRoot.join("aProject")

        for name in filenames {
            try await localFS.writeFileContents(sourceRoot.join(name)) { contents in
                contents <<< """
                    class \(name.mangledToC99ExtendedIdentifier()) {
                        let x = 1
                        func bar() {}
                    }
                    """
            }
        }

        tester = try await BuildOperationTester(testingCore.getCore(), testWorkspace, simulated: false)
        let parameters = BuildParameters(configuration: "Debug")
        buildRequest = BuildRequest(parameters: parameters, buildTargets: tester.workspace.projects[0].targets.map({ BuildRequest.BuildTargetInfo(parameters: parameters, target: $0) }), dependencyScope: .workspace, continueBuildingAfterErrors: true, useParallelTargets: true, useImplicitDependencies: false, useDryRun: false)
        try await tester.checkBuild(runDestination: .macOS, buildRequest: buildRequest, persistent: true) { results in
            try results.requireNoErrors()
        }
    }
}
