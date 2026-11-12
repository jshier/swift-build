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

import Benchmark
import SWBBenchmarkSupport

/// Dependency resolution and build planning of generated workspaces.
///
/// Benchmarks with cached settings measure a build shortly after the previous one: their workspace context keeps its
/// settings for the whole benchmark, and computes them in the warm-up iteration. Uncached benchmarks use a new
/// workspace context for each iteration.
let benchmarks: @Sendable () -> Void = {
    Benchmark.defaultConfiguration = .swiftBuild(maxDuration: .seconds(5), maxIterations: 5)

    // MARK: Resolution

    for scenario in [
        Scenario(kind: .hosttool, targetCount: 1000),
        Scenario(kind: .hosttool, targetCount: 1000, implicitPercentage: 50),
        Scenario(kind: .hosttool, targetCount: 1000, implicitPercentage: 100),
        Scenario(kind: .multiplatform, targetCount: 300),
        Scenario(kind: .index, targetCount: 300),
        Scenario(kind: .packages, targetCount: 300),
    ] {
        let name = "Resolution.\(scenario)"
        Benchmark.withFixture(name) {
            try await PlanningFixture(name, scenario, cachedSettings: true)
        } teardown: { fixture in
            await fixture.end()
        } _: { benchmark, fixture in
            _ = try await fixture.resolveGraph(fixture.workspaceContext())
        }
    }

    for scenario in [Scenario(kind: .hosttool, targetCount: 600), Scenario(kind: .hosttool, targetCount: 600, implicitPercentage: 50)] {
        let name = "ResolutionUncached.\(scenario)"
        Benchmark.withFixture(name) {
            try await PlanningFixture(name, scenario, cachedSettings: false)
        } _: { benchmark, fixture in
            let workspaceContext = fixture.workspaceContext()
            benchmark.startMeasurement()
            _ = try await fixture.resolveGraph(workspaceContext)
        }
    }

    let linkageScenario = Scenario(kind: .hosttool, targetCount: 1000)
    Benchmark.withFixture("LinkageGraphUncached.\(linkageScenario)") {
        try await PlanningFixture("LinkageGraphUncached.\(linkageScenario)", linkageScenario, cachedSettings: false)
    } _: { benchmark, fixture in
        let workspaceContext = fixture.workspaceContext()
        benchmark.startMeasurement()
        _ = try await fixture.resolveLinkageGraph(workspaceContext)
    }

    // MARK: Planning

    // Each iteration plans the graph resolved in setup.
    for scenario in [
        Scenario(kind: .hosttool, targetCount: 300),
        Scenario(kind: .hosttool, targetCount: 1000),
        Scenario(kind: .hosttool, targetCount: 300, implicitPercentage: 50),
        Scenario(kind: .multiplatform, targetCount: 300),
        Scenario(kind: .packages, targetCount: 300),
    ] {
        let name = "Planning.\(scenario)"
        Benchmark.withFixture(name) {
            let fixture = try await PlanningFixture(name, scenario, cachedSettings: true)
            return (fixture, try await fixture.resolveGraph(fixture.workspaceContext()))
        } teardown: { fixture, _ in
            await fixture.end()
        } _: { benchmark, setup in
            _ = try await setup.0.plan(setup.1, setup.0.workspaceContext())
        }
    }

    for scenario in [Scenario(kind: .hosttool, targetCount: 300), Scenario(kind: .packages, targetCount: 300)] {
        let name = "ResolutionAndPlanningUncached.\(scenario)"
        Benchmark.withFixture(name) {
            try await PlanningFixture(name, scenario, cachedSettings: false)
        } _: { benchmark, fixture in
            let workspaceContext = fixture.workspaceContext()
            benchmark.startMeasurement()
            _ = try await fixture.plan(fixture.resolveGraph(workspaceContext), workspaceContext)
        }
    }
}
