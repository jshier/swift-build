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

import Foundation
import SWBBenchmarkSupport
@_spi(Testing) import SWBCore
import SWBProtocol
import SWBTaskConstruction
import SWBTaskExecution
import SWBTestSupport
import SWBUtil
import Testing

/// A loaded workspace and the build requested for it, which benchmarks resolve and plan.
///
/// When `SWB_BENCHMARK_DUMP_DIRECTORY` is set, each benchmark writes the first graph or plan it produces there, to check that a change doesn't affect them.
final class PlanningFixture: Sendable {
    let name: String
    let core: Core
    let workspace: SWBCore.Workspace
    let fs: PseudoFS
    let buildRequest: BuildRequest
    /// For benchmarks with cached settings, the workspace context whose settings are kept alive until `end()`.
    private let cached: (context: WorkspaceContext, settings: KeptAliveSettings)?

    init(_ name: String, _ scenario: Scenario, cachedSettings: Bool) async throws {
        self.name = name
        let testingCore = TestingCore()
        core = try await testingCore.getCore()
        resetGUIDIdentifiers()
        let testWorkspace = try await makeWorkspace(scenario, testingCore: testingCore)
        workspace = try testWorkspace.load(core)
        fs = PseudoFS()
        for project in workspace.projects {
            try fs.createDirectory(project.sourceRoot, recursive: true)
            try fs.write(project.sourceRoot.join("file.swift"), contents: "")
        }

        let parameters: BuildParameters
        let buildTargets: [BuildRequest.BuildTargetInfo]
        if scenario.kind == .index {
            parameters = BuildParameters(action: .indexBuild, configuration: "Debug", activeRunDestination: nil, overrides: ["ONLY_ACTIVE_ARCH": "YES", "ALWAYS_SEARCH_USER_PATHS": "NO"], arena: .indexBuildArena(derivedDataRoot: workspace.path.dirname))
            buildTargets = workspace.projects[0].targets.map { BuildRequest.BuildTargetInfo(parameters: parameters, target: $0) }
        } else {
            parameters = BuildParameters(configuration: "Debug", activeRunDestination: .iOSSimulator)
            buildTargets = workspace.projects[0].targets.filter { $0.name == "App" }.map { BuildRequest.BuildTargetInfo(parameters: parameters, target: $0) }
        }
        buildRequest = BuildRequest(parameters: parameters, buildTargets: buildTargets, continueBuildingAfterErrors: true, useParallelTargets: true, useImplicitDependencies: scenario.implicitPercentage != nil, useDryRun: false)

        if cachedSettings {
            let context = Self.makeWorkspaceContext(core: core, workspace: workspace, fs: fs)
            cached = (context, await KeptAliveSettings(context))
        } else {
            cached = nil
        }
        try dump("workspace \(fingerprint(testWorkspace))\n", suffix: "workspace")
    }

    private static func makeWorkspaceContext(core: Core, workspace: SWBCore.Workspace, fs: PseudoFS) -> WorkspaceContext {
        let workspaceContext = WorkspaceContext(core: core, workspace: workspace, fs: fs, processExecutionCache: .sharedForTesting)
        workspaceContext.updateUserInfo(UserInfo(user: "exampleUser", group: "exampleGroup", uid: 1234, gid: 12345, home: Path("/Users/whoever"), environment: [:]))
        workspaceContext.updateSystemInfo(SystemInfo(operatingSystemVersion: Version(99, 98, 97), productBuildVersion: "99A98", nativeArchitecture: "arm64"))
        workspaceContext.updateUserPreferences(.defaultForTesting)
        return workspaceContext
    }

    /// The workspace context with cached settings, or a new one, so that nothing is cached.
    func workspaceContext() -> WorkspaceContext {
        cached?.context ?? Self.makeWorkspaceContext(core: core, workspace: workspace, fs: fs)
    }

    func resolveGraph(_ workspaceContext: WorkspaceContext) async throws -> TargetBuildGraph {
        let delegate = EmptyTargetDependencyResolverDelegate(workspace: workspace)
        let graph = await TargetBuildGraph(workspaceContext: workspaceContext, buildRequest: buildRequest, buildRequestContext: BuildRequestContext(workspaceContext: workspaceContext), delegate: delegate)
        try check(delegate.diagnostics, "resolution")
        try dump(describe(graph), suffix: "graph")
        return graph
    }

    func resolveLinkageGraph(_ workspaceContext: WorkspaceContext) async throws -> TargetLinkageGraph {
        let delegate = EmptyTargetDependencyResolverDelegate(workspace: workspace)
        let graph = await TargetLinkageGraph(workspaceContext: workspaceContext, buildRequest: buildRequest, buildRequestContext: BuildRequestContext(workspaceContext: workspaceContext), delegate: delegate)
        try check(delegate.diagnostics, "resolution")
        try dump(describe(graph), suffix: "linkage")
        return graph
    }

    func plan(_ graph: TargetBuildGraph, _ workspaceContext: WorkspaceContext) async throws -> BuildPlan {
        let buildRequestContext = BuildRequestContext(workspaceContext: workspaceContext)
        let provisioningInputs = Dictionary(uniqueKeysWithValues: graph.allTargets.map { ($0, TaskConstructionTester.computeProvisioningInputs(for: $0, workspaceContext: workspaceContext, buildRequest: buildRequest, buildRequestContext: buildRequestContext)) })
        let planRequest = BuildPlanRequest(workspaceContext: workspaceContext, buildRequest: buildRequest, buildRequestContext: buildRequestContext, buildGraph: graph, provisioningInputs: provisioningInputs)
        let delegate = TestTaskPlanningDelegate(clientDelegate: MockTestTaskPlanningClientDelegate(hostOS: core.hostOperatingSystem), workspace: workspace, fs: fs)
        guard let plan = await BuildPlan(planRequest: planRequest, taskPlanningDelegate: delegate) else {
            throw StubError.error("planning was cancelled")
        }
        try check(delegate.diagnostics, "planning")
        try dump(describe(plan, fs: fs), suffix: "plan")
        return plan
    }

    func end() async {
        await cached?.settings.end()
    }

    private func check(_ diagnostics: [ConfiguredTarget?: [Diagnostic]], _ phase: String) throws {
        if let error = diagnostics.values.joined().first(where: { $0.behavior == .error }) {
            throw StubError.error("\(phase) failed: \(error.formatLocalizedDescription(.debug))")
        }
    }

    /// Writes `contents` the first time each kind of result is produced, when dumping is requested.
    private func dump(_ contents: @autoclosure () throws -> String, suffix: String) throws {
        guard let directory = ProcessInfo.processInfo.environment["SWB_BENCHMARK_DUMP_DIRECTORY"] else { return }
        let path = URL(fileURLWithPath: directory).appendingPathComponent("\(name).\(suffix).txt")
        guard !FileManager.default.fileExists(atPath: path.path) else { return }
        try contents().write(to: path, atomically: true, encoding: .utf8)
    }
}
