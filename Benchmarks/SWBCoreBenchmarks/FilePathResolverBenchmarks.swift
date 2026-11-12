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

/// A file group, and a scope to resolve its path in.
private final class FilePathResolverFixture {
    let scope: MacroEvaluationScope
    /// A resolver that is reused for every resolution, so that all but the first use its file group cache.
    let resolver: FilePathResolver
    /// The root group, which owns the groups below it.
    let rootGroup: FileGroup
    let group: FileGroup

    /// Makes the group at `depth` levels below the root of `model`, and checks that it resolves to `expectedPath`.
    init(_ model: TestGroup, depth: Int, expectedPath: Path) throws {
        let namespace = MacroNamespace(parent: BuiltinMacros.namespace, debugDescription: "FilePathResolverBenchmarks")
        var table = MacroValueAssignmentTable(namespace: namespace)
        table.push(BuiltinMacros.PROJECT_DIR, literal: "/tmp/SomeProject")
        scope = MacroEvaluationScope(table: table)
        resolver = FilePathResolver(scope: scope)

        let pifLoader = PIFLoader(data: .plArray([]), namespace: BuiltinMacros.namespace)
        guard let rootGroup = try Reference.create(model.toProtocol(), pifLoader, isRoot: true) as? FileGroup else {
            throw StubError.error("the root reference isn't a group")
        }
        self.rootGroup = rootGroup
        var group = rootGroup
        for _ in 0..<depth {
            guard let child = group.children.first as? FileGroup else {
                throw StubError.error("the reference \(group.name) has no child group")
            }
            group = child
        }
        self.group = group

        let resolvedPath = FilePathResolver(scope: scope).resolveAbsolutePath(group, resolveParameterizedProductName: true)
        guard resolvedPath == expectedPath else {
            throw StubError.error("\(resolvedPath.str) was resolved instead of \(expectedPath.str)")
        }
    }
}

/// Registers a benchmark that resolves a group's path 100,000 times, with a new resolver each time unless `cached`.
private func resolutionBenchmark(_ name: String, cached: Bool, _ model: TestGroup, depth: Int = 0, expectedPath: Path) {
    Benchmark.withFixture("FilePathResolver.\(name)") {
        try FilePathResolverFixture(model, depth: depth, expectedPath: expectedPath)
    } _: { benchmark, fixture in
        if cached {
            for _ in 1...100000 {
                blackHole(fixture.resolver.resolveAbsolutePath(fixture.group, resolveParameterizedProductName: true))
            }
        } else {
            for _ in 1...100000 {
                let resolver = FilePathResolver(scope: fixture.scope)
                blackHole(resolver.resolveAbsolutePath(fixture.group, resolveParameterizedProductName: true))
            }
        }
    }
}

func filePathResolverBenchmarks() {
    resolutionBenchmark(
        "projectRelativeSourceTree_X100000", cached: false,
        TestGroup("SomeProject", path: "", sourceTree: .buildSetting("PROJECT_DIR")),
        expectedPath: Path("/tmp/SomeProject"))

    resolutionBenchmark(
        "projectRelativeSourceTree_Cached_X100000", cached: true,
        TestGroup("SomeProject", sourceTree: .buildSetting("PROJECT_DIR")),
        expectedPath: Path("/tmp/SomeProject"))

    resolutionBenchmark(
        "absoluteSourceTree_X100000", cached: false,
        TestGroup("SomeProject", path: "/tmp/AbsolutePath", sourceTree: .absolute),
        expectedPath: Path("/tmp/AbsolutePath"))

    resolutionBenchmark(
        "groupRelativeSourceTree_1Level_X100000", cached: false,
        TestGroup("SomeProject", path: "/tmp/SomeProject", sourceTree: .absolute, children: [TestGroup("AllFiles")]),
        depth: 1, expectedPath: Path("/tmp/SomeProject/AllFiles"))

    let twoLevels = TestGroup("SomeProject", path: "/tmp/SomeProject", sourceTree: .absolute, children: [TestGroup("AllFiles", children: [TestGroup("SomeFiles")])])

    resolutionBenchmark(
        "groupRelativeSourceTree_2Levels_X100000", cached: false,
        twoLevels,
        depth: 2, expectedPath: Path("/tmp/SomeProject/AllFiles/SomeFiles"))

    resolutionBenchmark(
        "groupRelativeSourceTree_2Levels_Cached_X100000", cached: true,
        twoLevels,
        depth: 2, expectedPath: Path("/tmp/SomeProject/AllFiles/SomeFiles"))
}
