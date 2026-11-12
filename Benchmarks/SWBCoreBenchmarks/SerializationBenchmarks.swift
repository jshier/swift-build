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
import SWBMacro
import SWBTestSupport
import SWBUtil
import Testing

/// The global scope of a trivial application target.
private final class TargetScopeFixture {
    let temporaryDirectory: NamedTemporaryDirectory
    let scope: MacroEvaluationScope

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
        let project = helper.project
        scope = helper.globalScope(buildRequestContext: BuildRequestContext(workspaceContext: helper.workspaceContext), project: project, target: project.targets[0])
    }
}

private struct MacroEvaluationScopeDeserializerDelegate: MacroValueAssignmentTableDeserializerDelegate {
    let namespace: MacroNamespace
}

private func serialize(_ scope: MacroEvaluationScope) -> MsgPackSerializer {
    let serializer = MsgPackSerializer()
    serializer.serialize(scope)
    return serializer
}

/// Registers a benchmark that serializes a target's scope `count` times.
private func serializationBenchmark(_ name: String, count: Int, configuration: Benchmark.Configuration = Benchmark.defaultConfiguration) {
    Benchmark.withFixture("Serialization.\(name)", configuration: configuration) {
        try await TargetScopeFixture()
    } _: { benchmark, fixture in
        var accumulatedBytes = 0
        for _ in 0..<count {
            accumulatedBytes += serialize(fixture.scope).byteString.count
        }
        blackHole(accumulatedBytes)
    }
}

/// Registers a benchmark that deserializes a target's scope `count` times.
private func deserializationBenchmark(_ name: String, count: Int, configuration: Benchmark.Configuration = Benchmark.defaultConfiguration) {
    Benchmark.withFixture("Serialization.\(name)", configuration: configuration) {
        let fixture = try await TargetScopeFixture()
        let serialized = serialize(fixture.scope).byteString
        let delegate = MacroEvaluationScopeDeserializerDelegate(namespace: fixture.scope.namespace)

        let deserialized: MacroEvaluationScope = try MsgPackDeserializer(serialized, delegate: delegate).deserialize()
        guard let projectName = fixture.scope.namespace.lookupMacroDeclaration("PROJECT_NAME"),
            let deserializedProjectName = deserialized.namespace.lookupMacroDeclaration("PROJECT_NAME"),
            fixture.scope.evaluateAsString(projectName) == deserialized.evaluateAsString(deserializedProjectName)
        else {
            throw StubError.error("the deserialized scope doesn't have the same PROJECT_NAME")
        }

        return (fixture: fixture, serialized: serialized, delegate: delegate)
    } _: { benchmark, setup in
        for _ in 0..<count {
            let scope: MacroEvaluationScope = try MsgPackDeserializer(setup.serialized, delegate: setup.delegate).deserialize()
            blackHole(scope)
        }
    }
}

func serializationBenchmarks() {
    serializationBenchmark("serializingTargetScopePerf_X100", count: 100)
    serializationBenchmark("serializingTargetScopePerf_X1000", count: 1000, configuration: .swiftBuild(maxIterations: 10))
    deserializationBenchmark("deserializingTargetScopePerf_X100", count: 100)
    deserializationBenchmark("deserializingTargetScopePerf_X1000", count: 1000, configuration: .swiftBuild(maxIterations: 10))
}
