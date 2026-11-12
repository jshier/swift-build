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
import SWBProtocol
import SWBTestSupport
import SWBUtil
import SwiftBuild
import SwiftBuildTestSupport
import Testing

/// Null builds of synthetic projects with a given number of targets and files.
func buildOperationBenchmarks() {
    for scenario in [
        // One target builds with varying file counts.
        NullBuildScenario("synthetic_NoHeaders_T1F10_X100", numTargets: 1, numFiles: 10, iterations: 100, maxIterations: 1),
        NullBuildScenario("synthetic_NoHeaders_T1F100_X100", numTargets: 1, numFiles: 100, iterations: 100, maxIterations: 1),
        NullBuildScenario("synthetic_NoHeaders_T1F1000_X10", numTargets: 1, numFiles: 1000, iterations: 10),

        // Multi-target builds with a constant total file count.
        NullBuildScenario("synthetic_NoHeaders_T10F100_X10", numTargets: 10, numFiles: 100, iterations: 10),
        NullBuildScenario("synthetic_NoHeaders_T100F10_X10", numTargets: 100, numFiles: 10, iterations: 10, maxIterations: 5),
        NullBuildScenario("synthetic_NoHeaders_T1000F1", numTargets: 1000, numFiles: 1, iterations: 1, maxIterations: 2),

        // One-target builds, with shared headers of varying counts.
        NullBuildScenario("synthetic_SharedHeaders_T1F1000H1_X10", numTargets: 1, numFiles: 1000, numHeaders: 1, iterations: 10),
        NullBuildScenario("synthetic_SharedHeaders_T1F1000H10_X10", numTargets: 1, numFiles: 1000, numHeaders: 10, iterations: 10),
        NullBuildScenario("synthetic_SharedHeaders_T1F1000H100_X10", numTargets: 1, numFiles: 1000, numHeaders: 100, iterations: 10),

        // One-target builds, with separate headers of varying counts.
        NullBuildScenario("synthetic_SeparateHeaders_T1F1000H10_X10", numTargets: 1, numFiles: 1000, numHeaders: 10, separateHeaders: true, iterations: 10),
    ] {
        Benchmark.withFixture("BuildOperation.\(scenario.name)", configuration: .swiftBuild(maxIterations: scenario.maxIterations)) {
            try await NullBuildFixture(scenario)
        } teardown: { fixture in
            try await fixture.close()
        } _: { (benchmark: Benchmark, fixture: NullBuildFixture) in
            for _ in 0..<scenario.iterations {
                blackHole(try await fixture.testSession.runBuildOperation(request: fixture.request, delegate: TestBuildOperationDelegate()))
            }
        }
    }
}

private struct NullBuildScenario {
    let name: String
    /// The number of targets to generate.
    let numTargets: Int
    /// The number of files to generate in each target.
    let numFiles: Int
    /// The number of headers to be included (transitively) in each target.
    let numHeaders: Int
    /// Whether the headers are shared by all files, or separate for all files.
    let separateHeaders: Bool
    /// The number of null builds in each benchmark iteration.
    let iterations: Int
    /// The maximum number of benchmark iterations, which keeps slow benchmarks short.
    let maxIterations: Int

    init(_ name: String, numTargets: Int, numFiles: Int, numHeaders: Int = 0, separateHeaders: Bool = false, iterations: Int, maxIterations: Int = 10) {
        self.name = name
        self.numTargets = numTargets
        self.numFiles = numFiles
        self.numHeaders = numHeaders
        self.separateHeaders = separateHeaders
        self.iterations = iterations
        self.maxIterations = maxIterations
    }
}

/// A synthetic project of command line tools, built once by a build service session.
private final class NullBuildFixture {
    let testSession: TestSWBSession
    let tester: CoreQualificationTester
    let request: SWBBuildRequest

    init(_ scenario: NullBuildScenario) async throws {
        let fs = localFS
        let temporaryDirectory = try NamedTemporaryDirectory()
        let tmpDir = temporaryDirectory.path
        let testSession = try await TestSWBSession(temporaryDirectory: temporaryDirectory)
        self.testSession = testSession
        do {
            let targets = (0..<scenario.numTargets).map { i in
                return TestStandardTarget(
                    "Tool-\(i)", type: .commandLineTool,
                    buildPhases: [
                        TestSourcesBuildPhase((0..<scenario.numFiles).map { TestBuildFile("File-\($0).c") }),
                        TestFrameworksBuildPhase(),
                    ],
                    provisioningSourceData: [
                        SWBProtocol.ProvisioningSourceData(
                            configurationName: "Debug",
                            provisioningStyle: .manual,
                            bundleIdentifierFromInfoPlist: "$(PRODUCT_BUNDLE_IDENTIFIER)")
                    ])
            }
            let allTarget = TestAggregateTarget("ALL", dependencies: targets.map { $0.name })
            let testProject = TestProject(
                "aProject",
                defaultConfigurationName: "Debug",
                groupTree: TestGroup("Root", children: (0..<scenario.numFiles).map { TestFile("File-\($0).c") }),
                buildConfigurations: [
                    TestBuildConfiguration(
                        "Debug",
                        buildSettings: [
                            "USE_HEADERMAP": "NO",
                            "PRODUCT_NAME": "$(TARGET_NAME)",
                        ])
                ],
                targets: [allTarget] + targets)
            let testWorkspace = TestWorkspace(
                "aWorkspace",
                sourceRoot: tmpDir.join("Test"),
                projects: [testProject])
            let SRCROOT = testWorkspace.sourceRoot.join("aProject")

            // Write the header files.
            if !scenario.separateHeaders {
                for i in 0..<scenario.numHeaders {
                    try await fs.writeFileContents(SRCROOT.join("Header-\(i).h")) { contents in
                        if i + 1 < scenario.numHeaders {
                            contents <<< "#include \"Header-\(i + 1).h\"\n"
                        }
                    }
                }
            }

            // Write the source files.
            for i in 0..<scenario.numFiles {
                if scenario.separateHeaders {
                    for j in 0..<scenario.numHeaders {
                        try await fs.writeFileContents(SRCROOT.join("File-\(i)-\(j).h")) { contents in
                            if j + 1 < scenario.numHeaders {
                                contents <<< "#include \"File-\(i)-\(j + 1).h\"\n"
                            }
                        }
                    }
                }

                try await fs.writeFileContents(SRCROOT.join("File-\(i).c")) { contents in
                    if scenario.numHeaders != 0 {
                        if scenario.separateHeaders {
                            contents <<< "#include \"File-\(i)-0.h\"\n\n"
                        } else {
                            contents <<< "#include \"Header-0.h\"\n\n"
                        }
                    }

                    if i == 0 {
                        contents <<< "int main() { return 0; }\n"
                    } else {
                        contents <<< "void f\(i)(void) {}\n"
                    }
                }
            }

            tester = try await CoreQualificationTester(testWorkspace, testSession, fs: fs)

            var request = SWBBuildRequest()
            request.useParallelTargets = true
            request.parameters = SWBBuildParameters()
            request.parameters.action = "build"
            request.parameters.configurationName = "Debug"
            request.add(target: SWBConfiguredTarget(guid: allTarget.guid, parameters: nil))
            self.request = request

            // Suppress a linker warning.
            try fs.createDirectory(SRCROOT.join("build/Debug"), recursive: true)

            let events = try await testSession.runBuildOperation(request: request, delegate: TestBuildOperationDelegate())
            try events.requireNoErrors()
            guard events.taskStartedMessages.count > scenario.numTargets * scenario.numFiles, events.upToDateTargetCount == 0 else {
                throw StubError.error("The initial build didn't build every target")
            }

            // Check that the benchmark measures null builds.
            let nullBuildEvents = try await testSession.runBuildOperation(request: request, delegate: TestBuildOperationDelegate())
            try nullBuildEvents.requireNoErrors()
            let expectedRuleTypes: Set = ["CreateBuildDescription", "ComputeTargetDependencyGraph", "GatherProvisioningInputs", "ClangStatCache", "PruneExplicitPrecompiledModules", "ReportTargetDependencyGraph"]
            let unexpectedTasks = nullBuildEvents.taskStartedMessages.filter { !expectedRuleTypes.contains(String($0.ruleInfo.prefix { $0 != " " })) }
            guard unexpectedTasks.isEmpty, nullBuildEvents.allOutput().bytes.isEmpty, nullBuildEvents.upToDateTargetCount == scenario.numTargets else {
                throw StubError.error("The second build wasn't a null build; it ran \(unexpectedTasks.map(\.ruleInfo))")
            }
        } catch {
            try? await testSession.close()
            throw error
        }
    }

    func close() async throws {
        try await tester.invalidate()
        try await testSession.close()
    }
}
