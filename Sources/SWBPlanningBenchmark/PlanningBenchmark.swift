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
import Synchronization
import SWBLibc
@_spi(Testing) import SWBCore
import SWBProtocol
import SWBTaskConstruction
import SWBTaskExecution
import SWBTestSupport
import SWBUtil
import Testing

private let usage = """
    usage: SWBPlanningBenchmark [--scenario NAME] [--targets N] [--implicit PERCENT] [--iterations N] [--mode warm|cold]
                                [--linkage] [--plan] [--allocations] [--dump FILE] [--plan-dump FILE]

    Resolves the target dependency graph of a generated workspace, and optionally plans its build, reporting the wall time,
    instructions, cycles, peak memory, and optionally heap allocations of each iteration. The same options always generate
    the same workspace, and the report starts with a fingerprint of it.

      --scenario     hosttool (default): an iOS app whose frameworks depend on layers of static libraries, and some on a
                     host tool with its own dependencies.
                     multiplatform: the same, with an embedded watchOS app sharing libraries with the iOS app.
                     index: the index workspace description of the hosttool workspace, for every platform.
                     packages: an iOS app whose frameworks depend on the products of a package.
      --targets      The approximate number of targets (default 342).
      --implicit     Uses implicit dependencies, with PERCENT of the frameworks and libraries depended on only through the
                     Frameworks build phases of their dependents. Every target then links its dependencies, so that
                     different percentages differ only in their explicit dependencies. Not available for packages.
      --iterations   The number of measured iterations (default 5).
      --mode         warm (default) measures with the settings of the workspace cached, as for a build shortly after the
                     previous one. cold measures with a new workspace context for each iteration, so nothing is cached.
      --linkage      Resolves the target linkage graph instead of the build graph.
      --plan         Also plans the build, and reports the planning time separately.
      --allocations  Counts heap allocations, which slows down allocation-heavy work.
      --dump         Writes the resolved graph, to check that a change doesn't affect it.
      --plan-dump    Plans the build, and writes the planned tasks and the contents of the files they write.
    """

private struct Options {
    var scenario = "hosttool"
    var targetCount = 342
    var implicitPercentage: Int?
    var iterations = 5
    var cold = false
    var linkage = false
    var plan = false
    var countAllocations = false
    var dumpPath: String?
    var planDumpPath: String?

    init(_ arguments: [String]) throws {
        var arguments = arguments.makeIterator()
        func value(_ option: String) throws -> String {
            guard let value = arguments.next() else { throw StubError.error("\(option) requires a value") }
            return value
        }
        func count(_ option: String) throws -> Int {
            guard let count = Int(try value(option)), count > 0 else { throw StubError.error("\(option) requires a positive integer") }
            return count
        }
        while let argument = arguments.next() {
            switch argument {
            case "--scenario": scenario = try value(argument)
            case "--targets": targetCount = try count(argument)
            case "--implicit":
                guard let percentage = Int(try value(argument)), (0...100).contains(percentage) else { throw StubError.error("\(argument) requires a percentage from 0 to 100") }
                implicitPercentage = percentage
            case "--iterations": iterations = try count(argument)
            case "--mode":
                switch try value(argument) {
                case "warm": cold = false
                case "cold": cold = true
                case let mode: throw StubError.error("unknown mode '\(mode)'")
                }
            case "--linkage": linkage = true
            case "--plan": plan = true
            case "--allocations": countAllocations = true
            case "--dump": dumpPath = try value(argument)
            case "--plan-dump": plan = true; planDumpPath = try value(argument)
            default: throw StubError.error("unknown argument '\(argument)'")
            }
        }
    }
}

// MARK: Measurement

/// The resources used by the process so far, where the platform reports them.
private struct ResourceUsage {
    var instructions: UInt64?
    var cycles: UInt64?
    var allocations: Int?
    var allocatedBytes: Int?

    #if canImport(Darwin)
    static var current: ResourceUsage {
        var info = rusage_info_v6()
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V6, $0) }
        }
        return ResourceUsage(instructions: result == 0 ? info.ri_instructions : nil, cycles: result == 0 ? info.ri_cycles : nil, allocations: allocationCount.load(ordering: .relaxed), allocatedBytes: allocationBytes.load(ordering: .relaxed))
    }
    #else
    static var current: ResourceUsage { ResourceUsage() }
    #endif

    static func - (lhs: ResourceUsage, rhs: ResourceUsage) -> ResourceUsage {
        func difference<T: Numeric>(_ value: KeyPath<ResourceUsage, T?>) -> T? {
            lhs[keyPath: value].flatMap { end in rhs[keyPath: value].map { end - $0 } }
        }
        return ResourceUsage(instructions: difference(\.instructions), cycles: difference(\.cycles), allocations: difference(\.allocations), allocatedBytes: difference(\.allocatedBytes))
    }
}

#if canImport(Darwin)
private let allocationCount = Atomic<Int>(0)
private let allocationBytes = Atomic<Int>(0)

private typealias MallocLogger = @convention(c) (UInt32, UInt, UInt, UInt, UInt, UInt32) -> Void

/// Counts allocations through libmalloc's logging hook, which receives `MALLOC_LOG_TYPE_ALLOCATE` (2) for each allocation, along with `MALLOC_LOG_TYPE_DEALLOCATE` (4) and the new size in the third argument for a reallocation.
private let mallocLogger: MallocLogger = { type, _, size, reallocatedSize, _, _ in
    guard type & 2 != 0 else { return }
    allocationCount.add(1, ordering: .relaxed)
    allocationBytes.add(Int(type & 4 != 0 ? reallocatedSize : size), ordering: .relaxed)
}

private var mallocLoggerPointer: UnsafeMutablePointer<MallocLogger?>? {
    dlsym(UnsafeMutableRawPointer(bitPattern: -2), "malloc_logger").map { $0.assumingMemoryBound(to: MallocLogger?.self) }
}
#endif

private var canCountAllocations: Bool {
    #if canImport(Darwin)
    return mallocLoggerPointer != nil
    #else
    return false
    #endif
}

private func setCountingAllocations(_ counting: Bool) {
    #if canImport(Darwin)
    mallocLoggerPointer?.pointee = counting ? mallocLogger : nil
    #endif
}

/// The peak memory use of the process: the physical footprint on Darwin, and the peak resident or working set size elsewhere.
private func peakMemory() -> UInt64? {
    #if canImport(Darwin)
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
    }
    return result == KERN_SUCCESS ? UInt64(info.ledger_phys_footprint_peak) : nil
    #elseif os(Windows)
    var counters = PROCESS_MEMORY_COUNTERS()
    guard K32GetProcessMemoryInfo(GetCurrentProcess(), &counters, DWORD(MemoryLayout<PROCESS_MEMORY_COUNTERS>.size)) else { return nil }
    return UInt64(counters.PeakWorkingSetSize)
    #else
    // Linux reports the peak resident set size in kilobytes.
    guard let status = try? String(contentsOfFile: "/proc/self/status", encoding: .utf8), let line = status.split(separator: "\n").first(where: { $0.hasPrefix("VmHWM:") }), let kilobytes = UInt64(line.split(separator: " ").dropFirst().first ?? "") else { return nil }
    return kilobytes * 1024
    #endif
}

private struct Sample {
    var wallTime: Duration
    var planningTime: Duration?
    var usage: ResourceUsage
}

private func measure(countingAllocations: Bool, _ body: () async throws -> Duration?) async rethrows -> Sample {
    let startUsage = ResourceUsage.current
    setCountingAllocations(countingAllocations)
    let start = ContinuousClock.now
    let planningTime = try await body()
    let wallTime = ContinuousClock.now - start
    setCountingAllocations(false)
    return Sample(wallTime: wallTime, planningTime: planningTime, usage: ResourceUsage.current - startUsage)
}

// MARK: Workspace generation

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

/// Provides the testing core, and the tools of its default toolchain, as task construction tests do.
private struct TestingCore: CoreBasedTests {}

private func makeWorkspace(_ options: Options, testingCore: TestingCore) async throws -> TestWorkspace {
    let projectSettings = try await ["PRODUCT_NAME": "$(TARGET_NAME)", "MACOSX_DEPLOYMENT_TARGET": "26.0", "GENERATE_INFOPLIST_FILE": "YES", "SWIFT_EXEC": testingCore.swiftCompilerPath.str, "SWIFT_VERSION": testingCore.swiftVersion, "LIBTOOL": testingCore.libtoolPath.str]
    var projects = [TestProject]()
    switch options.scenario {
    case "hosttool", "index", "multiplatform":
        projects.append(TestProject("aProject", groupTree: TestGroup("Sources", children: [TestFile("file.swift")]), buildConfigurations: [TestBuildConfiguration("Debug", buildSettings: projectSettings)], targets: layeredTargets(count: options.targetCount, implicitPercentage: options.implicitPercentage, watch: options.scenario == "multiplatform")))
    case "packages" where options.implicitPercentage != nil:
        throw StubError.error("--implicit isn't available for packages")
    case "packages":
        let targets = packageTargets(count: options.targetCount)
        projects.append(TestProject("aProject", groupTree: TestGroup("Sources", children: [TestFile("file.swift")]), buildConfigurations: [TestBuildConfiguration("Debug", buildSettings: projectSettings)], targets: targets.appTargets))
        projects.append(TestPackageProject("Package", groupTree: TestGroup("PackageSources", children: [TestFile("file.swift", guid: "package-file")]), buildConfigurations: [TestBuildConfiguration("Debug", buildSettings: projectSettings)], targets: targets.packageTargets))
    default:
        throw StubError.error("unknown scenario '\(options.scenario)'")
    }
    return TestWorkspace("Workspace", sourceRoot: Path("/tmp/SWBPlanningBenchmark"), projects: projects)
}

/// A hash of the workspace's PIF objects, which identifies the generated workspace. Their only integers are the bytes of their serialized contents.
private func fingerprint(_ workspace: TestWorkspace) throws -> String {
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

private func describe(_ graph: TargetBuildGraph) -> String {
    graph.allTargets.map { configuredTarget in
        let overrides = configuredTarget.parameters.overrides.sorted(byKey: <).map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        return (["\(configuredTarget.guid) [\(overrides)]"] + graph.resolvedDependencies(of: configuredTarget).map { "    -> \($0.target.guid) \($0.reason)" }).joined(separator: "\n")
    }.joined(separator: "\n") + "\n"
}

private func describe(_ graph: TargetLinkageGraph) -> String {
    graph.allTargets.sorted().map { configuredTarget in
        ([configuredTarget.guid.stringValue] + graph.dependencies(of: configuredTarget).map { "    -> \($0.guid)" }).joined(separator: "\n")
    }.joined(separator: "\n") + "\n"
}

private func describe(_ plan: BuildPlan, fs: any FSProxy) -> String {
    plan.tasks.map { task in
        var line = "\(task.ruleInfo.joined(separator: " ")) | in: \(task.inputs.map(\.name).sorted().joined(separator: " ")) | out: \(task.outputs.map(\.name).sorted().joined(separator: " ")) | cmd: \(task.execTask.commandLineAsStrings.joined(separator: " "))"
        if let action = (task.execTask as? SWBTaskExecution.Task)?.action as? AuxiliaryFileTaskAction {
            line += " | contents: \((try? fs.read(action.context.input).asString) ?? "<unreadable>")"
        }
        return line
    }.sorted().joined(separator: "\n") + "\n"
}

private func milliseconds(_ duration: Duration) -> Double {
    Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
}

private func median<T: Comparable>(_ values: [T]) -> T {
    values.sorted()[values.count / 2]
}

// MARK: Benchmark

@main
struct PlanningBenchmark {
    static func main() async {
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            if arguments.contains("--help") {
                print(usage)
                return
            }
            try await run(Options(arguments))
        } catch {
            FileHandle.standardError.write(Data("SWBPlanningBenchmark: \(error)\n\n\(usage)\n".utf8))
            exit(1)
        }
    }

    private static func run(_ options: Options) async throws {
        if options.countAllocations && !canCountAllocations {
            throw StubError.error("allocations can't be counted on this platform")
        }

        let testingCore = TestingCore()
        let core = try await testingCore.getCore()
        let testWorkspace = try await makeWorkspace(options, testingCore: testingCore)
        let workspace = try testWorkspace.load(core)
        let fs = PseudoFS()
        for project in workspace.projects {
            try fs.createDirectory(project.sourceRoot, recursive: true)
            try fs.write(project.sourceRoot.join("file.swift"), contents: "")
        }

        let parameters: BuildParameters
        let buildTargets: [BuildRequest.BuildTargetInfo]
        if options.scenario == "index" {
            parameters = BuildParameters(action: .indexBuild, configuration: "Debug", activeRunDestination: nil, overrides: ["ONLY_ACTIVE_ARCH": "YES", "ALWAYS_SEARCH_USER_PATHS": "NO"], arena: .indexBuildArena(derivedDataRoot: workspace.path.dirname))
            buildTargets = workspace.projects[0].targets.map { BuildRequest.BuildTargetInfo(parameters: parameters, target: $0) }
        } else {
            parameters = BuildParameters(configuration: "Debug", activeRunDestination: .iOSSimulator)
            buildTargets = workspace.projects[0].targets.filter { $0.name == "App" }.map { BuildRequest.BuildTargetInfo(parameters: parameters, target: $0) }
        }
        let buildRequest = BuildRequest(parameters: parameters, buildTargets: buildTargets, continueBuildingAfterErrors: true, useParallelTargets: true, useImplicitDependencies: options.implicitPercentage != nil, useDryRun: false)

        func makeWorkspaceContext() -> WorkspaceContext {
            let workspaceContext = WorkspaceContext(core: core, workspace: workspace, fs: fs, processExecutionCache: .sharedForTesting)
            workspaceContext.updateUserInfo(UserInfo(user: "exampleUser", group: "exampleGroup", uid: 1234, gid: 12345, home: Path("/Users/whoever"), environment: [:]))
            workspaceContext.updateSystemInfo(SystemInfo(operatingSystemVersion: Version(99, 98, 97), productBuildVersion: "99A98", nativeArchitecture: "arm64"))
            workspaceContext.updateUserPreferences(.defaultForTesting)
            return workspaceContext
        }

        var graphDescription: String?
        var planDescription: String?
        var targetCount = 0
        var taskCount = 0

        /// Resolves the graph, and plans the build if requested, returning the time spent planning.
        func iterate(_ workspaceContext: WorkspaceContext) async throws -> Duration? {
            let buildRequestContext = BuildRequestContext(workspaceContext: workspaceContext)
            let delegate = EmptyTargetDependencyResolverDelegate(workspace: workspace)
            var planningTime: Duration?
            if options.linkage {
                let graph = await TargetLinkageGraph(workspaceContext: workspaceContext, buildRequest: buildRequest, buildRequestContext: buildRequestContext, delegate: delegate)
                targetCount = graph.allTargets.count
                graphDescription = graphDescription ?? (options.dumpPath != nil ? describe(graph) : nil)
            } else {
                let graph = await TargetBuildGraph(workspaceContext: workspaceContext, buildRequest: buildRequest, buildRequestContext: buildRequestContext, delegate: delegate)
                targetCount = graph.allTargets.count
                graphDescription = graphDescription ?? (options.dumpPath != nil ? describe(graph) : nil)
                if options.plan {
                    let start = ContinuousClock.now
                    let provisioningInputs = Dictionary(uniqueKeysWithValues: graph.allTargets.map { ($0, TaskConstructionTester.computeProvisioningInputs(for: $0, workspaceContext: workspaceContext, buildRequest: buildRequest, buildRequestContext: buildRequestContext)) })
                    let planRequest = BuildPlanRequest(workspaceContext: workspaceContext, buildRequest: buildRequest, buildRequestContext: buildRequestContext, buildGraph: graph, provisioningInputs: provisioningInputs)
                    let planningDelegate = TestTaskPlanningDelegate(clientDelegate: MockTestTaskPlanningClientDelegate(hostOS: core.hostOperatingSystem), workspace: workspace, fs: fs)
                    guard let plan = await BuildPlan(planRequest: planRequest, taskPlanningDelegate: planningDelegate) else {
                        throw StubError.error("planning was cancelled")
                    }
                    planningTime = ContinuousClock.now - start
                    if let error = planningDelegate.diagnostics.values.joined().first(where: { $0.behavior == .error }) {
                        throw StubError.error("planning failed: \(error.formatLocalizedDescription(.debug))")
                    }
                    taskCount = plan.tasks.count
                    planDescription = planDescription ?? (options.planDumpPath != nil ? describe(plan, fs: fs) : nil)
                }
            }
            if let error = delegate.diagnostics.values.joined().first(where: { $0.behavior == .error }) {
                throw StubError.error("resolution failed: \(error.formatLocalizedDescription(.debug))")
            }
            return planningTime
        }

        var workspaceContext = makeWorkspaceContext()
        let memoryBefore = peakMemory()
        var samples = [Sample]()
        // Keep the settings alive across iterations, as a build does while it's planned.
        try await BuildRequestContext(workspaceContext: workspaceContext).keepAliveSettingsCache {
            if !options.cold {
                _ = try await iterate(workspaceContext)
            }
            for _ in 0..<options.iterations {
                if options.cold {
                    workspaceContext = makeWorkspaceContext()
                }
                samples.append(try await measure(countingAllocations: options.countAllocations) { try await iterate(workspaceContext) })
            }
        }
        let memoryAfter = peakMemory()

        if let path = options.dumpPath, let graphDescription {
            try graphDescription.write(toFile: path, atomically: true, encoding: .utf8)
        }
        if let path = options.planDumpPath, let planDescription {
            try planDescription.write(toFile: path, atomically: true, encoding: .utf8)
        }

        let wallTimes = samples.map { milliseconds($0.wallTime) }
        let implicitDescription = options.implicitPercentage.map { " \($0)% implicit" } ?? ""
        var report = "\(options.scenario)\(implicitDescription) \(options.cold ? "cold" : "warm")\(options.linkage ? " linkage" : ""): \(targetCount) targets resolved, workspace \(try fingerprint(testWorkspace))"
        report += String(format: "\n  wall time       min %.1f ms, median %.1f ms", wallTimes.min() ?? 0, median(wallTimes))
        let planningTimes = samples.compactMap(\.planningTime).map(milliseconds)
        if !planningTimes.isEmpty {
            report += String(format: "\n  planning time   min %.1f ms, median %.1f ms, %d tasks", planningTimes.min() ?? 0, median(planningTimes), taskCount)
        }
        func reportMedian<T: BinaryInteger>(_ label: String, _ value: KeyPath<ResourceUsage, T?>, scale: Double = 1e6, unit: String = " M") {
            let values = samples.compactMap { $0.usage[keyPath: value] }
            report += "\n  " + label.padding(toLength: 16, withPad: " ", startingAt: 0) + (values.isEmpty ? "not available" : String(format: "median %.1f%@", Double(median(values)) / scale, unit))
        }
        reportMedian("instructions", \.instructions)
        reportMedian("cycles", \.cycles)
        if options.countAllocations {
            reportMedian("allocations", \.allocations, scale: 1e3, unit: " K")
            reportMedian("allocated", \.allocatedBytes, unit: " MB")
        }
        report += "\n  peak memory     " + (memoryAfter.map { after in String(format: "%.1f MB, %.1f MB before measuring", Double(after) / 1e6, Double(memoryBefore ?? 0) / 1e6) } ?? "not available")
        print(report)
    }
}
