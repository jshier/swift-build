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
import SWBTestSupport
import SWBUtil
import SwiftBuild
import SwiftBuildTestSupport

func buildServiceBenchmarks() {
    // The time to launch, ping, and shut down the service.
    Benchmark("BuildService.isAlivePerfX10", configuration: .swiftBuild(maxIterations: 10)) { (benchmark: Benchmark) async throws in
        for _ in 0..<10 {
            let service = try await SWBBuildService()
            try await service.checkAlive()
            await service.close()
        }
    }

    Benchmark.withFixture("BuildService.oneMessagePerfX10000", configuration: .swiftBuild(maxIterations: 10)) {
        try await makeService()
    } teardown: { service in
        await service.close()
    } _: { (benchmark: Benchmark, service: SWBBuildService) in
        for _ in 0..<10000 {
            try await service.checkAlive()
        }
    }

    Benchmark.withFixture("BuildService.oneMessageAsyncPerfX10000", configuration: .swiftBuild(maxIterations: 10)) {
        try await makeService()
    } teardown: { service in
        await service.close()
    } _: { (benchmark: Benchmark, service: SWBBuildService) in
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<10000 {
                group.addTask {
                    try await service.checkAlive()
                }
            }

            // Wait for the last reply.
            try await group.waitForAll()
        }
    }

    Benchmark.withFixture("BuildService.singleMacroEvaluationPerf_X1000", configuration: .swiftBuild(maxIterations: 100)) {
        try await MacroEvaluationFixture()
    } teardown: { fixture in
        try await fixture.close()
    } _: { (benchmark: Benchmark, fixture: MacroEvaluationFixture) in
        for _ in 0..<1000 {
            blackHole(try await fixture.session.evaluateMacroAsString("PROJECT_NAME", level: .target("T1"), buildParameters: fixture.parameters, overrides: nil))
        }
    }

    // Throughput benchmarks.

    for (name, payloadSize, messageCount) in [("throughput_1K_Message_X10000", 1 << 10, 10000), ("throughput_1MB_Message_X100", 1 << 20, 100)] {
        Benchmark.withFixture("BuildService.\(name)", configuration: .swiftBuild(maxIterations: 10)) {
            try await (makeService(), Array(repeating: UInt8(ascii: "T"), count: payloadSize))
        } teardown: { service, _ in
            await service.close()
        } _: { (benchmark: Benchmark, fixture: (service: SWBBuildService, payload: [UInt8])) in
            for _ in 0..<messageCount {
                blackHole(try await fixture.service.sendThroughputTest(fixture.payload))
            }
        }
    }
}

/// Launches the service, and ensures that it's up.
private func makeService() async throws -> SWBBuildService {
    let service = try await SWBBuildService()
    do {
        try await service.checkAlive()
    } catch {
        await service.close()
        throw error
    }
    return service
}

/// A session that has loaded a workspace with one application target.
private final class MacroEvaluationFixture {
    let service: SWBBuildService
    let session: SWBBuildServiceSession
    let parameters: SWBBuildParameters

    init() async throws {
        var parameters = SWBBuildParameters()
        parameters.action = "build"
        parameters.configurationName = "Config1"
        self.parameters = parameters

        let service = try await SWBBuildService()
        self.service = service
        do {
            let (result, diagnostics) = await service.createSession(name: "test", cachePath: nil)
            guard diagnostics.isEmpty else {
                throw StubError.error("Creating the session failed: \(diagnostics)")
            }
            session = try result.get()
        } catch {
            await service.close()
            throw error
        }

        do {
            let workspacePIF: SWBPropertyListItem = [
                "guid": "W1",
                "name": "aWorkspace",
                "path": "/tmp/aWorkspace.xcworkspace/contents.xcworkspacedata",
                "projects": ["P1"],
            ]
            let projectPIF: SWBPropertyListItem = [
                "guid": "P1",
                "path": "/tmp/aProject.xcodeproj",
                "groupTree": [
                    "guid": "G1",
                    "type": "group",
                    "name": "SomeFiles",
                    "sourceTree": "PROJECT_DIR",
                    "path": "/tmp/SomeProject/SomeFiles",
                ],
                "buildConfigurations": [
                    [
                        "guid": "BC1",
                        "name": "Config1",
                        "buildSettings": [
                            "USER_PROJECT_SETTING": "USER_PROJECT_VALUE"
                        ],
                    ]
                ],
                "targets": ["T1"],
                "defaultConfigurationName": "Config1",
                "developmentRegion": "English",
            ]
            let targetPIF: SWBPropertyListItem = [
                "guid": "T1",
                "name": "Target1",
                "type": "standard",
                "productTypeIdentifier": "com.apple.product-type.application",
                "productReference": [
                    "guid": "PR1",
                    "name": "MyApp.app",
                ],
                "buildPhases": [],
                "buildConfigurations": [
                    [
                        "guid": "C2",
                        "name": "Config1",
                        "buildSettings": [
                            "PRODUCT_NAME": "MyApp"
                        ],
                    ]
                ],
                "dependencies": [],
                "buildRules": [],
            ]
            let topLevelPIF: SWBPropertyListItem = [
                [
                    "type": "workspace",
                    "signature": "W1",
                    "contents": workspacePIF,
                ],
                [
                    "type": "project",
                    "signature": "P1",
                    "contents": projectPIF,
                ],
                [
                    "type": "target",
                    "signature": "T1",
                    "contents": targetPIF,
                ],
            ]

            try await session.sendPIF(topLevelPIF)

            let projectName = try await session.evaluateMacroAsString("PROJECT_NAME", level: .target("T1"), buildParameters: parameters, overrides: nil)
            guard projectName == "aProject" else {
                throw StubError.error("PROJECT_NAME is '\(projectName)', not 'aProject'")
            }
        } catch {
            try? await close()
            throw error
        }
    }

    func close() async throws {
        let result = await Result { try await session.close() }
        await service.close()
        try result.get()
    }
}
