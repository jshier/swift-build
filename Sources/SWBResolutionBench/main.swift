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

// A benchmark of target dependency graph resolution and build planning, for generated graphs of a given size: wall time, instructions, cycles, peak memory, and optionally heap allocations.
//
// Build it with `SWB_ENABLE_RESOLUTION_BENCHMARK=1 swift build -c release --product SWBResolutionBench`.
//
// usage: SWBResolutionBench [--scenario hosttool|multiplatform|implicit|index|packages] [--targets N] [--iterations N]
//                           [--mode cold|warm] [--linkage] [--plan] [--allocs] [--dump FILE] [--plan-dump FILE] [--quiet]
//
//   --scenario     hosttool: an iOS app whose frameworks and libraries use a host tool with its own dependencies.
//                  multiplatform: the same, with an embedded watchOS app sharing libraries with the iOS app.
//                  implicit: the same as hosttool, with half of the dependencies implicit, through the Frameworks build phase.
//                  index: the index workspace description of the hosttool graph, which configures each target for each platform.
//                  packages: an iOS app whose frameworks depend on the products of a package.
//   --mode         warm (the default) resolves with the settings of the graph cached, as for a build within a minute of the previous one; cold resolves with no cached settings.
//   --linkage      resolves the target linkage graph instead.
//   --plan         also plans the build, and reports the time to do so separately.
//   --allocs       counts heap allocations, which slows down resolution, especially concurrent resolution.
//   --dump         writes the resolved graph, to compare the results of different builds.
//   --plan-dump    plans the build, and writes the planned tasks, including the contents of the files they write.

import Foundation
import Darwin
import Synchronization
@_spi(Testing) import SWBCore
import SWBProtocol
import SWBTestSupport
import SWBTaskConstruction
import SWBTaskExecution
import SWBUtil
import Testing

// MARK: Allocation counting, through libmalloc's logging hook.

let allocationCount = Atomic<Int>(0)
let allocationBytes = Atomic<Int>(0)
typealias MallocLogger = @convention(c) (UInt32, UInt, UInt, UInt, UInt, UInt32) -> Void
let mallocLogger: MallocLogger = { type, _, size, reallocSize, _, _ in
    // MALLOC_LOG_TYPE_ALLOCATE = 2, MALLOC_LOG_TYPE_DEALLOCATE = 4 (both for realloc, with the new size in the third argument).
    guard type & 2 != 0 else { return }
    allocationCount.add(1, ordering: .relaxed)
    allocationBytes.add(Int(type & 4 != 0 ? reallocSize : size), ordering: .relaxed)
}
let mallocLoggerPointer = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "malloc_logger")!.assumingMemoryBound(to: MallocLogger?.self)

func usage() -> rusage_info_v6 {
    var info = rusage_info_v6()
    withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { _ = proc_pid_rusage(getpid(), RUSAGE_INFO_V6, $0) } }
    return info
}

struct Sample {
    var wall: Duration
    var instructions: UInt64
    var cycles: UInt64
    var allocations: Int
    var bytes: Int
}

func measure(_ body: () async -> Void) async -> Sample {
    let startUsage = usage()
    let startCount = allocationCount.load(ordering: .relaxed)
    let startBytes = allocationBytes.load(ordering: .relaxed)
    if countAllocations { mallocLoggerPointer.pointee = mallocLogger }
    let start = ContinuousClock.now
    await body()
    let wall = ContinuousClock.now - start
    mallocLoggerPointer.pointee = nil
    let endUsage = usage()
    return Sample(wall: wall, instructions: endUsage.ri_instructions - startUsage.ri_instructions, cycles: endUsage.ri_cycles - startUsage.ri_cycles, allocations: allocationCount.load(ordering: .relaxed) - startCount, bytes: allocationBytes.load(ordering: .relaxed) - startBytes)
}

// MARK: Options

var scenario = "hosttool"
var targetCount = 342
var iterations = 5
var mode = "warm"
var linkage = false
var dumpPath: String? = nil
var quiet = false
var countAllocations = false
var plan = false
var planDumpPath: String? = nil
var planDescription = ""
var arguments = CommandLine.arguments.dropFirst().makeIterator()
while let argument = arguments.next() {
    switch argument {
    case "--scenario": scenario = arguments.next()!
    case "--targets": targetCount = Int(arguments.next()!)!
    case "--iterations": iterations = Int(arguments.next()!)!
    case "--mode": mode = arguments.next()!
    case "--linkage": linkage = true
    case "--dump": dumpPath = arguments.next()!
    case "--quiet": quiet = true
    case "--allocs": countAllocations = true
    case "--plan": plan = true
    case "--plan-dump": plan = true; planDumpPath = arguments.next()!
    default: fatalError("unknown argument \(argument)")
    }
}

// MARK: Graph generation

struct SplitMix64 {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    mutating func next(below bound: Int) -> Int { Int(next() % UInt64(bound)) }
}

let autoSettings = ["SDKROOT": "auto", "SUPPORTED_PLATFORMS": "macosx iphoneos iphonesimulator watchos watchsimulator"]

func target(_ name: String, type: TestStandardTarget.TargetType, buildSettings: [String: String] = autoSettings, dependencies: [String], linked: [String] = []) -> TestStandardTarget {
    var buildPhases: [any TestBuildPhase] = [TestSourcesBuildPhase(["file.swift"])]
    if !linked.isEmpty {
        buildPhases.append(TestFrameworksBuildPhase(linked.map { TestBuildFile(.target($0)) }))
    }
    return TestStandardTarget(name, type: type, buildConfigurations: [TestBuildConfiguration("Debug", buildSettings: buildSettings)], buildPhases: buildPhases, dependencies: dependencies.map { TestTargetDependency($0) })
}

/// A layered graph of about `count` targets: an iOS app depending on frameworks, which depend on static libraries in lower layers, and a host tool with its own chain of dependencies used by some of the frameworks.
func layeredTargets(count: Int, implicit: Bool, watch: Bool) -> (targets: [any TestTarget], topLevel: [String]) {
    var random = SplitMix64(state: 0x5EED)
    let hostToolDependencyCount = max(10, count / 20)
    let frameworkCount = max(4, count * 15 / 100)
    let libraryCount = max(8, count - frameworkCount - hostToolDependencyCount - 3)
    let window = max(8, libraryCount / 8)

    var targets = [any TestTarget]()
    var appDependencies = (0..<frameworkCount).map { "Framework\($0)" }
    if watch {
        appDependencies.append("WatchApp")
    }
    targets.append(target("App", type: .application, buildSettings: ["SDKROOT": "iphoneos", "SUPPORTED_PLATFORMS": "iphoneos iphonesimulator"], dependencies: appDependencies))
    if watch {
        targets.append(target("WatchApp", type: .watchKitApp, buildSettings: ["SDKROOT": "watchos", "SUPPORTED_PLATFORMS": "watchos watchsimulator"], dependencies: (0..<max(2, libraryCount / 5)).map { "Library\($0 * 5 % libraryCount)" }))
    }
    for index in 0..<frameworkCount {
        var dependencies = Set<String>()
        while dependencies.count < 4 { dependencies.insert("Library\(random.next(below: libraryCount))") }
        var explicit = dependencies.sorted()
        var linked = [String]()
        if implicit {
            // Half of the dependencies are only implied by the Frameworks build phase.
            linked = explicit
            explicit = Array(explicit.prefix(2))
        }
        if index % 10 == 0 { explicit.append("HostTool") }
        targets.append(target("Framework\(index)", type: .framework, dependencies: explicit, linked: linked))
    }
    for index in 0..<libraryCount {
        var dependencies = Set<String>()
        let lower = index + 1
        let upper = min(libraryCount, lower + window)
        if lower < upper {
            for _ in 0..<min(4, upper - lower) { dependencies.insert("Library\(lower + random.next(below: upper - lower))") }
        }
        var explicit = dependencies.sorted()
        var linked = [String]()
        if implicit {
            linked = explicit
            explicit = Array(explicit.prefix(explicit.count / 2))
        }
        targets.append(target("Library\(index)", type: .staticLibrary, dependencies: explicit, linked: linked))
    }
    targets.append(target("HostTool", type: .hostBuildTool, buildSettings: ["SDKROOT": "auto"], dependencies: ["HostToolDependency0"]))
    for index in 0..<hostToolDependencyCount {
        var dependencies = [String]()
        for next in [index + 1, index + 3] where next < hostToolDependencyCount { dependencies.append("HostToolDependency\(next)") }
        targets.append(target("HostToolDependency\(index)", type: .staticLibrary, dependencies: dependencies))
    }
    return (targets, ["App"])
}

/// An iOS app whose frameworks depend on the products of a package, whose library targets depend on each other and on other products.
func packageTargets(count: Int) -> (appTargets: [any TestTarget], packageTargets: [any TestTarget], topLevel: [String]) {
    var random = SplitMix64(state: 0xC0FFEE)
    let frameworkCount = max(4, count / 10)
    let productCount = max(4, (count - frameworkCount) / 2)
    let window = max(8, productCount / 8)
    let packageSettings = ["SDKROOT": "auto", "SDK_VARIANT": "auto", "SUPPORTED_PLATFORMS": "macosx iphoneos iphonesimulator appletvos appletvsimulator watchos watchsimulator"]

    var appTargets = [any TestTarget]()
    appTargets.append(target("App", type: .application, buildSettings: ["SDKROOT": "iphoneos", "SUPPORTED_PLATFORMS": "iphoneos iphonesimulator"], dependencies: (0..<frameworkCount).map { "Framework\($0)" }))
    for index in 0..<frameworkCount {
        var dependencies = Set<String>()
        while dependencies.count < 3 { dependencies.insert("Product\(random.next(below: productCount))") }
        appTargets.append(target("Framework\(index)", type: .framework, buildSettings: ["SDKROOT": "iphoneos", "SUPPORTED_PLATFORMS": "iphoneos iphonesimulator"], dependencies: dependencies.sorted()))
    }
    var packageTargets = [any TestTarget]()
    for index in 0..<productCount {
        packageTargets.append(TestPackageProductTarget("Product\(index)", frameworksBuildPhase: TestFrameworksBuildPhase([TestBuildFile(.target("PackageLibrary\(index)"))]), buildConfigurations: [TestBuildConfiguration("Debug", buildSettings: packageSettings)], dependencies: ["PackageLibrary\(index)"]))
    }
    for index in 0..<productCount {
        var dependencies = Set<String>()
        let lower = index + 1
        let upper = min(productCount, lower + window)
        if lower < upper {
            for _ in 0..<min(2, upper - lower) { dependencies.insert("PackageLibrary\(lower + random.next(below: upper - lower))") }
            dependencies.insert("Product\(lower + random.next(below: upper - lower))")
        }
        packageTargets.append(target("PackageLibrary\(index)", type: .staticLibrary, buildSettings: packageSettings, dependencies: dependencies.sorted()))
    }
    return (appTargets, packageTargets, ["App"])
}

let generated: (targets: [any TestTarget], topLevel: [String])
var packageProjectTargets = [any TestTarget]()
switch scenario {
case "hosttool", "index": generated = layeredTargets(count: targetCount, implicit: false, watch: false)
case "multiplatform": generated = layeredTargets(count: targetCount, implicit: false, watch: true)
case "implicit": generated = layeredTargets(count: targetCount, implicit: true, watch: false)
case "packages":
    let packages = packageTargets(count: targetCount)
    generated = (packages.appTargets, packages.topLevel)
    packageProjectTargets = packages.packageTargets
default: fatalError("unknown scenario \(scenario)")
}

// MARK: Setup

let core = try await Core.createInitializedTestingCore(pluginLoadingFilter: { _ in true }, registerExtraPlugins: { _ in })
let setupStart = ContinuousClock.now
let workspace = try TestWorkspace("Workspace", sourceRoot: Path("/tmp/SWBResolutionBench"), projects: [
    TestProject(
        "aProject",
        groupTree: TestGroup("Sources", children: [TestFile("file.swift")]),
        buildConfigurations: [TestBuildConfiguration("Debug", buildSettings: ["PRODUCT_NAME": "$(TARGET_NAME)", "MACOSX_DEPLOYMENT_TARGET": "26.0"])],
        targets: generated.targets)
] + (packageProjectTargets.isEmpty ? [] : [
    TestPackageProject("Package", groupTree: TestGroup("PackageSources", children: [TestFile("file.swift", guid: "package-file")]), buildConfigurations: [TestBuildConfiguration("Debug", buildSettings: ["PRODUCT_NAME": "$(TARGET_NAME)", "MACOSX_DEPLOYMENT_TARGET": "26.0"])], targets: packageProjectTargets)
])).load(core)
let setupTime = ContinuousClock.now - setupStart

let buildRequest: BuildRequest
if scenario == "index" {
    let arena = ArenaInfo.indexBuildArena(derivedDataRoot: workspace.path.dirname)
    let parameters = BuildParameters(action: .indexBuild, configuration: "Debug", activeRunDestination: nil, overrides: ["ONLY_ACTIVE_ARCH": "YES", "ALWAYS_SEARCH_USER_PATHS": "NO"], arena: arena)
    let buildTargets = workspace.projects[0].targets.filter { $0.type != .aggregate }.map { BuildRequest.BuildTargetInfo(parameters: parameters, target: $0) }
    buildRequest = BuildRequest(parameters: parameters, buildTargets: buildTargets, continueBuildingAfterErrors: true, useParallelTargets: true, useImplicitDependencies: false, useDryRun: false)
} else {
    let parameters = BuildParameters(configuration: "Debug", activeRunDestination: .iOSSimulator)
    let buildTargets = generated.topLevel.map { name in BuildRequest.BuildTargetInfo(parameters: parameters, target: workspace.projects[0].targets.first { $0.name == name }!) }
    buildRequest = BuildRequest(parameters: parameters, buildTargets: buildTargets, continueBuildingAfterErrors: true, useParallelTargets: true, useImplicitDependencies: scenario == "implicit", useDryRun: false)
}

// MARK: Run

func describe(_ graph: TargetBuildGraph) -> String {
    var lines = [String]()
    for configuredTarget in graph.allTargets {
        let overrides = configuredTarget.parameters.overrides.sorted(byKey: <).map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        lines.append("\(configuredTarget.guid) [\(overrides)]")
        for dependency in graph.resolvedDependencies(of: configuredTarget) {
            lines.append("    -> \(dependency.target.guid) \(dependency.reason)")
        }
    }
    return lines.joined(separator: "\n") + "\n"
}

func describe(_ graph: TargetLinkageGraph) -> String {
    var lines = [String]()
    for configuredTarget in graph.allTargets.sorted() {
        lines.append("\(configuredTarget.guid)")
        for dependency in graph.dependencies(of: configuredTarget) {
            lines.append("    -> \(dependency.guid)")
        }
    }
    return lines.joined(separator: "\n") + "\n"
}

let fs = PseudoFS()
try fs.createDirectory(workspace.path.dirname.join("aProject"), recursive: true)
for project in workspace.projects {
    try fs.createDirectory(project.sourceRoot, recursive: true)
    try fs.write(project.sourceRoot.join("file.swift"), contents: "")
}
func makeWorkspaceContext() -> WorkspaceContext {
    let workspaceContext = WorkspaceContext(core: core, workspace: workspace, fs: fs, processExecutionCache: .sharedForTesting)
    workspaceContext.updateUserInfo(UserInfo(user: "exampleUser", group: "exampleGroup", uid: 1234, gid: 12345, home: Path("/Users/whoever"), environment: [:]))
    workspaceContext.updateSystemInfo(SystemInfo(operatingSystemVersion: Version(99, 98, 97), productBuildVersion: "99A98", nativeArchitecture: "arm64"))
    workspaceContext.updateUserPreferences(UserPreferences.defaultForTesting)
    return workspaceContext
}
var workspaceContext = makeWorkspaceContext()
var planSamples = [Duration]()
var tasksPlanned = 0
var samples = [Sample]()
var resultDescription = ""
var targetsResolved = 0
var edgesResolved = 0
let footprintBefore = usage().ri_phys_footprint

func resolveOnce() async {
    let buildRequestContext = BuildRequestContext(workspaceContext: workspaceContext)
    let delegate = EmptyTargetDependencyResolverDelegate(workspace: workspace)
    if linkage {
        let graph = await TargetLinkageGraph(workspaceContext: workspaceContext, buildRequest: buildRequest, buildRequestContext: buildRequestContext, delegate: delegate)
        targetsResolved = graph.allTargets.count
        edgesResolved = graph.allTargets.reduce(0) { $0 + graph.dependencies(of: $1).count }
        if dumpPath != nil && resultDescription.isEmpty { resultDescription = describe(graph) }
    } else {
        let graph = await TargetBuildGraph(workspaceContext: workspaceContext, buildRequest: buildRequest, buildRequestContext: buildRequestContext, delegate: delegate)
        targetsResolved = graph.allTargets.count
        edgesResolved = graph.allTargets.reduce(0) { $0 + graph.dependencies(of: $1).count }
        if dumpPath != nil && resultDescription.isEmpty { resultDescription = describe(graph) }
        if plan {
            let planStart = ContinuousClock.now
            let planningDelegate = TestTaskPlanningDelegate(clientDelegate: MockTestTaskPlanningClientDelegate(hostOS: core.hostOperatingSystem), workspace: workspace, fs: fs)
            var provisioningInputs = [ConfiguredTarget: ProvisioningTaskInputs]()
            for target in graph.allTargets {
                provisioningInputs[target] = TaskConstructionTester.computeProvisioningInputs(for: target, workspaceContext: workspaceContext, buildRequest: buildRequest, buildRequestContext: buildRequestContext)
            }
            let planRequest = BuildPlanRequest(workspaceContext: workspaceContext, buildRequest: buildRequest, buildRequestContext: buildRequestContext, buildGraph: graph, provisioningInputs: provisioningInputs)
            let buildPlan = await BuildPlan(planRequest: planRequest, taskPlanningDelegate: planningDelegate)
            tasksPlanned = buildPlan?.tasks.count ?? -1
            planSamples.append(ContinuousClock.now - planStart)
            if let buildPlan, planDumpPath != nil, planDescription.isEmpty {
                var lines = [String]()
                for task in buildPlan.tasks {
                    var line = task.ruleInfo.joined(separator: " ") + " | in: " + task.inputs.map(\.name).sorted().joined(separator: " ") + " | out: " + task.outputs.map(\.name).sorted().joined(separator: " ") + " | cmd: " + task.execTask.commandLineAsStrings.joined(separator: " ")
                    if let action = (task.execTask as? SWBTaskExecution.Task)?.action as? AuxiliaryFileTaskAction {
                        line += " | contents: " + ((try? fs.read(action.context.input).asString) ?? "<unreadable>")
                    }
                    lines.append(line)
                }
                planDescription = lines.sorted().joined(separator: "\n") + "\n"
            }
        }
    }
    let errors = delegate.diagnostics.values.joined().filter { $0.behavior == .error }
    if !errors.isEmpty {
        fatalError("resolution errors: \(errors.map { $0.formatLocalizedDescription(.debug) })")
    }
}

await workspaceContext.workspaceSettingsCache_keepAlive {
    if mode == "warm" {
        // Prime the settings cache.
        await resolveOnce()
    }
    for _ in 0..<iterations {
        if mode == "cold" {
            workspaceContext = makeWorkspaceContext()
        }
        samples.append(await measure { await resolveOnce() })
    }
}

if let planDumpPath {
    try planDescription.write(toFile: planDumpPath, atomically: true, encoding: .utf8)
}
if let dumpPath {
    try resultDescription.write(toFile: dumpPath, atomically: true, encoding: .utf8)
}

func median<T: Comparable>(_ values: [T]) -> T { values.sorted()[values.count / 2] }
let finalUsage = usage()
let ms = { (d: Duration) in Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15 }
let walls = samples.map { ms($0.wall) }
print(String(format: "%@ %@ targets=%d resolved=%d edges=%d  wall min %.1f ms med %.1f ms  instr med %.1f M  cycles med %.1f M  allocs med %d  bytes med %.1f MB  peak footprint %.1f MB (before %.1f MB)  setup %.1f s",
             scenario, mode + (linkage ? "+linkage" : ""), targetCount, targetsResolved, edgesResolved,
             walls.min()!, median(walls),
             Double(median(samples.map(\.instructions))) / 1e6, Double(median(samples.map(\.cycles))) / 1e6,
             median(samples.map(\.allocations)), Double(median(samples.map(\.bytes))) / 1e6,
             Double(finalUsage.ri_lifetime_max_phys_footprint) / 1e6, Double(footprintBefore) / 1e6, Double(setupTime.components.seconds)))
if plan {
    let planMs = planSamples.suffix(samples.count).map(ms)
    print(String(format: "  planning: tasks=%d  min %.1f ms  med %.1f ms (included in wall above)", tasksPlanned, planMs.min() ?? 0, planMs.isEmpty ? 0 : median(planMs)))
}
if !quiet {
    for sample in samples {
        print(String(format: "  %.1f ms  %.1f M instr  %d allocs", ms(sample.wall), Double(sample.instructions) / 1e6, sample.allocations))
    }
}

extension WorkspaceContext {
    func workspaceSettingsCache_keepAlive(_ body: () async -> Void) async {
        await BuildRequestContext(workspaceContext: self).keepAliveSettingsCache(body)
    }
}
