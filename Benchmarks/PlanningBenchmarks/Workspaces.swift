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

import SWBBenchmarkSupport
import SWBCore
import SWBProtocol
import SWBTaskConstruction
import SWBTaskExecution
import SWBTestSupport
import SWBUtil
import Testing

/// A deterministic random number generator, so that each run generates the same workspace.
private struct SplitMix64 {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }

    /// Returns a number in `range` as `Int.random(in:using:)` does on 64-bit platforms, which the standard library doesn't guarantee.
    mutating func next(in range: Range<Int>) -> Int {
        let bound = UInt64(range.count)
        var product = next().multipliedFullWidth(by: bound)
        if product.low < bound {
            let threshold = (0 &- bound) % bound
            while product.low < threshold {
                product = next().multipliedFullWidth(by: bound)
            }
        }
        return range.lowerBound + Int(product.high)
    }
}

private func target(_ name: String, type: TestStandardTarget.TargetType, buildSettings: [String: String], dependencies: [String], linked: [String] = []) -> TestStandardTarget {
    var buildPhases: [any TestBuildPhase] = [TestSourcesBuildPhase(["file.swift"])]
    if !linked.isEmpty {
        buildPhases.append(TestFrameworksBuildPhase(linked.map { TestBuildFile(.target($0)) }))
    }
    return TestStandardTarget(name, type: type, buildConfigurations: [TestBuildConfiguration("Debug", buildSettings: buildSettings)], buildPhases: buildPhases, dependencies: dependencies.map { TestTargetDependency($0) })
}

/// Picks `count` distinct names from `prefix` followed by the numbers in `range`, sorted.
private func pick(_ count: Int, _ prefix: String, from range: Range<Int>, using random: inout SplitMix64) -> [String] {
    var picked = Set<Int>()
    while picked.count < min(count, range.count) {
        picked.insert(random.next(in: range))
    }
    return picked.sorted().map { "\(prefix)\($0)" }
}

/// An iOS app depending on frameworks, which depend on layers of static libraries, and some of them on a host tool with its own chain of dependencies.
private func layeredTargets(count: Int, implicitPercentage: Int?, watch: Bool) -> [any TestTarget] {
    var random = SplitMix64(state: 0x5EED)
    let autoSettings = ["SDKROOT": "auto", "SUPPORTED_PLATFORMS": "macosx iphoneos iphonesimulator watchos watchsimulator"]
    let hostToolDependencyCount = max(10, count / 20)
    let frameworkCount = max(4, count * 15 / 100)
    let libraryCount = max(8, count - frameworkCount - hostToolDependencyCount - 3)
    let window = max(8, libraryCount / 8)

    // With implicit dependencies, every target links its dependencies, and an evenly spread `implicitPercentage` of each
    // kind of linked target is depended on only that way.
    var implicitTargets = Set<String>()
    if let implicitPercentage {
        for (prefix, count) in [("Framework", frameworkCount), ("Library", libraryCount), ("HostToolDependency", hostToolDependencyCount)] {
            implicitTargets.formUnion((0..<count).filter { ($0 + 1) * implicitPercentage / 100 > $0 * implicitPercentage / 100 }.map { "\(prefix)\($0)" })
        }
    }
    func layeredTarget(_ name: String, type: TestStandardTarget.TargetType, buildSettings: [String: String], dependencies: [String], unlinked: [String] = []) -> TestStandardTarget {
        guard implicitPercentage != nil else {
            return target(name, type: type, buildSettings: buildSettings, dependencies: dependencies + unlinked)
        }
        return target(name, type: type, buildSettings: buildSettings, dependencies: dependencies.filter { !implicitTargets.contains($0) } + unlinked, linked: dependencies)
    }

    var targets = [any TestTarget]()
    targets.append(layeredTarget("App", type: .application, buildSettings: ["SDKROOT": "iphoneos", "SUPPORTED_PLATFORMS": "iphoneos iphonesimulator"], dependencies: (0..<frameworkCount).map { "Framework\($0)" }, unlinked: watch ? ["WatchApp"] : []))
    if watch {
        targets.append(layeredTarget("WatchApp", type: .application, buildSettings: ["SDKROOT": "watchos", "SUPPORTED_PLATFORMS": "watchos watchsimulator"], dependencies: (0..<max(2, libraryCount / 5)).map { "Library\($0 * 5 % libraryCount)" }))
    }
    for index in 0..<frameworkCount {
        targets.append(layeredTarget("Framework\(index)", type: .framework, buildSettings: autoSettings, dependencies: pick(4, "Library", from: 0..<libraryCount, using: &random), unlinked: index % 10 == 0 ? ["HostTool"] : []))
    }
    for index in 0..<libraryCount {
        targets.append(layeredTarget("Library\(index)", type: .staticLibrary, buildSettings: autoSettings, dependencies: pick(4, "Library", from: (index + 1)..<min(libraryCount, index + 1 + window), using: &random)))
    }
    targets.append(layeredTarget("HostTool", type: .hostBuildTool, buildSettings: ["SDKROOT": "auto"], dependencies: ["HostToolDependency0"]))
    for index in 0..<hostToolDependencyCount {
        targets.append(layeredTarget("HostToolDependency\(index)", type: .staticLibrary, buildSettings: autoSettings, dependencies: [index + 1, index + 3].filter { $0 < hostToolDependencyCount }.map { "HostToolDependency\($0)" }))
    }
    return targets
}

/// An iOS app whose frameworks depend on the products of a package, whose library targets depend on each other and on other products.
private func packageTargets(count: Int) -> (appTargets: [any TestTarget], packageTargets: [any TestTarget]) {
    var random = SplitMix64(state: 0xC0FFEE)
    let iOSSettings = ["SDKROOT": "iphoneos", "SUPPORTED_PLATFORMS": "iphoneos iphonesimulator"]
    let packageSettings = ["SDKROOT": "auto", "SDK_VARIANT": "auto", "SUPPORTED_PLATFORMS": "macosx iphoneos iphonesimulator appletvos appletvsimulator watchos watchsimulator"]
    let frameworkCount = max(4, count / 10)
    let productCount = max(4, (count - frameworkCount) / 2)
    let window = max(8, productCount / 8)

    var appTargets: [any TestTarget] = [target("App", type: .application, buildSettings: iOSSettings, dependencies: (0..<frameworkCount).map { "Framework\($0)" })]
    for index in 0..<frameworkCount {
        appTargets.append(target("Framework\(index)", type: .framework, buildSettings: iOSSettings, dependencies: pick(3, "Product", from: 0..<productCount, using: &random)))
    }
    var packageTargets = [any TestTarget]()
    for index in 0..<productCount {
        packageTargets.append(TestPackageProductTarget("Product\(index)", frameworksBuildPhase: TestFrameworksBuildPhase([TestBuildFile(.target("PackageLibrary\(index)"))]), buildConfigurations: [TestBuildConfiguration("Debug", buildSettings: packageSettings)], dependencies: ["PackageLibrary\(index)"]))
    }
    for index in 0..<productCount {
        let range = (index + 1)..<min(productCount, index + 1 + window)
        let dependencies = range.isEmpty ? [] : pick(2, "PackageLibrary", from: range, using: &random) + pick(1, "Product", from: range, using: &random)
        packageTargets.append(target("PackageLibrary\(index)", type: .staticLibrary, buildSettings: packageSettings, dependencies: dependencies.sorted()))
    }
    return (appTargets, packageTargets)
}

func fingerprint(_ workspace: TestWorkspace) throws -> String {
    var bytes = [UInt8]()
    func append(_ item: PropertyListItem) {
        switch item {
        case let .plDict(dictionary):
            for (key, value) in dictionary.sorted(byKey: <) {
                bytes += key.utf8
                append(value)
            }
        case let .plArray(array): array.forEach(append)
        case let .plString(string): bytes += string.utf8
        case let .plInt(byte): bytes.append(UInt8(truncatingIfNeeded: byte))
        default: bytes += String(describing: item).utf8
        }
    }
    try workspace.toObjects().forEach(append)
    let context = SHA256Context()
    context.add(bytes: bytes)
    return String(context.signature.asString.prefix(12))
}

// MARK: Results

func describe(_ graph: TargetBuildGraph) -> String {
    graph.allTargets.map { configuredTarget in
        let overrides = configuredTarget.parameters.overrides.sorted(byKey: <).map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        return (["\(configuredTarget.guid) [\(overrides)]"] + graph.resolvedDependencies(of: configuredTarget).map { "    -> \($0.target.guid) \($0.reason)" }).joined(separator: "\n")
    }.joined(separator: "\n") + "\n"
}

func describe(_ graph: TargetLinkageGraph) -> String {
    graph.allTargets.sorted().map { configuredTarget in
        ([configuredTarget.guid.stringValue] + graph.dependencies(of: configuredTarget).map { "    -> \($0.guid)" }).joined(separator: "\n")
    }.joined(separator: "\n") + "\n"
}

func describe(_ plan: BuildPlan, fs: any FSProxy) -> String {
    plan.tasks.map { task in
        var line = "\(task.ruleInfo.joined(separator: " ")) | in: \(task.inputs.map(\.name).sorted().joined(separator: " ")) | out: \(task.outputs.map(\.name).sorted().joined(separator: " ")) | cmd: \(task.execTask.commandLineAsStrings.joined(separator: " "))"
        if let action = (task.execTask as? SWBTaskExecution.Task)?.action as? AuxiliaryFileTaskAction {
            line += " | contents: \((try? fs.read(action.context.input).asString) ?? "<unreadable>")"
        }
        return line
    }.sorted().joined(separator: "\n") + "\n"
}

// MARK: Scenarios

/// A generated workspace, and the build that's requested for it.
struct Scenario: Sendable, CustomStringConvertible {
    enum Kind: String, Sendable {
        /// An iOS app whose frameworks depend on layers of static libraries, and some on a host tool with its own dependencies.
        case hosttool
        /// The same, with an embedded watchOS app sharing libraries with the iOS app.
        case multiplatform
        /// The index workspace description of the hosttool workspace, for every platform.
        case index
        /// An iOS app whose frameworks depend on the products of a package.
        case packages
    }

    var kind: Kind
    var targetCount: Int
    /// With implicit dependencies, the percentage of frameworks and libraries depended on only through the Frameworks build phases of their dependents. Every target then links its dependencies, so that different percentages differ only in their explicit dependencies.
    var implicitPercentage: Int? = nil

    var description: String {
        "\(kind.rawValue)\(implicitPercentage.map { "-implicit\($0)" } ?? "").\(targetCount)"
    }
}

func makeWorkspace(_ scenario: Scenario, testingCore: TestingCore) async throws -> TestWorkspace {
    let projectSettings = try await ["PRODUCT_NAME": "$(TARGET_NAME)", "MACOSX_DEPLOYMENT_TARGET": "26.0", "GENERATE_INFOPLIST_FILE": "YES", "SWIFT_EXEC": testingCore.swiftCompilerPath.str, "SWIFT_VERSION": testingCore.swiftVersion, "LIBTOOL": testingCore.libtoolPath.str]
    var projects = [TestProject]()
    switch scenario.kind {
    case .hosttool, .index, .multiplatform:
        projects.append(TestProject("aProject", groupTree: TestGroup("Sources", children: [TestFile("file.swift")]), buildConfigurations: [TestBuildConfiguration("Debug", buildSettings: projectSettings)], targets: layeredTargets(count: scenario.targetCount, implicitPercentage: scenario.implicitPercentage, watch: scenario.kind == .multiplatform)))
    case .packages:
        precondition(scenario.implicitPercentage == nil, "implicit dependencies aren't available for packages")
        let targets = packageTargets(count: scenario.targetCount)
        projects.append(TestProject("aProject", groupTree: TestGroup("Sources", children: [TestFile("file.swift")]), buildConfigurations: [TestBuildConfiguration("Debug", buildSettings: projectSettings)], targets: targets.appTargets))
        projects.append(TestPackageProject("Package", groupTree: TestGroup("PackageSources", children: [TestFile("file.swift", guid: "package-file")]), buildConfigurations: [TestBuildConfiguration("Debug", buildSettings: projectSettings)], targets: targets.packageTargets))
    }
    return TestWorkspace("Workspace", sourceRoot: Path("/tmp/SWBPlanningBenchmark"), projects: projects)
}
