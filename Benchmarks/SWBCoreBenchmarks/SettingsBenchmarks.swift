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

/// A trivial native application target.
private final class TargetFixture {
    let temporaryDirectory: NamedTemporaryDirectory
    let workspaceContext: WorkspaceContext
    let buildRequestContext: BuildRequestContext
    let project: SWBCore.Project
    let target: SWBCore.Target
    let parameters = BuildParameters(action: .build, configuration: "Debug")

    init() async throws {
        temporaryDirectory = try NamedTemporaryDirectory()
        let helper = try await TestWorkspace(
            "Workspace",
            sourceRoot: temporaryDirectory.path,
            projects: [
                TestProject(
                    "aProject",
                    groupTree: TestGroup("SomeFiles"),
                    targets: [TestStandardTarget("Target1", type: .application)])
            ]
        ).loadHelper(TestingCore().getCore())
        workspaceContext = helper.workspaceContext
        buildRequestContext = BuildRequestContext(workspaceContext: workspaceContext)
        project = helper.project
        target = project.targets[0]
    }
}

func settingsBenchmarks() {
    Benchmark.withFixture("Settings.targetSettingsPerf_X100") {
        try await TargetFixture()
    } _: { benchmark, fixture in
        for _ in 0..<100 {
            blackHole(Settings(workspaceContext: fixture.workspaceContext, buildRequestContext: fixture.buildRequestContext, parameters: fixture.parameters, project: fixture.project, target: fixture.target, includeExports: false))
        }
    }
}
