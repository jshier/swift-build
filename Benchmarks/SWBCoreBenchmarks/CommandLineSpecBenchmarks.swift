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
@_spi(Testing) import SWBCore
import SWBMacro
import enum SWBProtocol.ExternalToolResult
import struct SWBProtocol.BuildOperationTaskEnded
import SWBTaskExecution
import SWBTestSupport
import SWBUtil
import Synchronization
import Testing

private final class CapturingTaskGenerationDelegate: TaskGenerationDelegate {
    private let _diagnosticsEngine = DiagnosticsEngine()
    let producer: any CommandProducer
    let userPreferences: UserPreferences
    let diagnosticContext: DiagnosticContextData
    let sharedIntermediateNodes = Registry<String, (any PlannedNode, any Sendable)>()

    init(producer: any CommandProducer, userPreferences: UserPreferences) throws {
        self.producer = producer
        self.userPreferences = userPreferences
        self.diagnosticContext = DiagnosticContextData(target: nil)
    }

    func diagnosticsEngine(for target: ConfiguredTarget?) -> DiagnosticProducingDelegateProtocolPrivate<DiagnosticsEngine> {
        .init(_diagnosticsEngine)
    }

    let shellTasksCount = SWBMutex<Int>(0)

    func beginActivity(ruleInfo: String, executionDescription: String, signature: ByteString, target: ConfiguredTarget?, parentActivity: ActivityID?) -> ActivityID {
        .init(rawValue: -1)
    }

    func endActivity(id: ActivityID, signature: ByteString, status: BuildOperationTaskEnded.Status) {
    }

    func emit(data: [UInt8], for activity: ActivityID, signature: ByteString) {
    }

    func emit(diagnostic: Diagnostic, for activity: ActivityID, signature: ByteString) {
    }

    var hadErrors: Bool {
        _diagnosticsEngine.hasErrors
    }

    // TaskGenerationDelegate

    func warning(_ message: String) {}
    func error(_ message: String) {}
    func createVirtualNode(_ name: String) -> PlannedVirtualNode {
        return MakePlannedVirtualNode(name)
    }
    func createNode(_ path: Path) -> PlannedPathNode {
        let absolutePath = Path.root.join("tmp").join(path)
        return MakePlannedPathNode(absolutePath)
    }
    func createDirectoryTreeNode(_ path: Path, excluding: [String]) -> PlannedDirectoryTreeNode {
        let absolutePath = Path.root.join("tmp").join(path)
        return MakePlannedDirectoryTreeNode(absolutePath, excluding: excluding)
    }
    func createBuildDirectoryNode(absolutePath path: Path) -> PlannedPathNode {
        return createNode(path)
    }
    func declareOutput(_ file: FileToBuild) {}
    func declareGeneratedSourceFile(_ path: Path) {}
    func declareGeneratedInfoPlistContent(_ path: Path) {}
    func declareGeneratedPrivacyPlistContent(_ path: Path) {}
    func declareGeneratedTBDFile(_ path: Path, forVariant variant: String) {}
    func declareGeneratedSwiftObjectiveCHeaderFile(_ path: Path, architecture: String) {}
    func declareGeneratedSwiftConstMetadataFile(_ path: Path, architecture: String) {}
    var additionalCodeSignInputs: OrderedSet<Path> { return [] }
    var buildDirectories: Set<Path> { return [] }

    func createTask(_ builder: inout PlannedTaskBuilder) {
        shellTasksCount.withLock { $0 += 1 }
    }
    func createGateTask(inputs: [any PlannedNode], output: any PlannedNode, name: String?, mustPrecede: [any PlannedTask], taskConfiguration: (inout PlannedTaskBuilder) -> Void) {
        // Store somewhere if a test needs it.
    }
    func createOrReuseSharedNodeWithIdentifier(_ ident: String, creator: () -> (any PlannedNode, any Sendable)) -> (any PlannedNode, any Sendable) {
        return sharedIntermediateNodes.getOrInsert(ident, creator)
    }
    func registerSharedPCHOrderingDependency(_ ident: String, orderingNode: any PlannedNode) {}
    func access(path: Path) {}
    func readFileContents(_ path: Path) throws -> ByteString { return ByteString() }
    func recordAttachment(contents: SWBUtil.ByteString) -> SWBUtil.Path {
        Path("")
    }
    func fileExists(at path: Path) -> Bool { return true }
    public var taskActionCreationDelegate: any TaskActionCreationDelegate { return self }
    public var clientDelegate: any CoreClientDelegate { return self }
}

extension CapturingTaskGenerationDelegate: TaskActionCreationDelegate {
    public func createAuxiliaryFileTaskAction(_ context: AuxiliaryFileTaskActionContext) -> any PlannedTaskAction {
        return AuxiliaryFileTaskAction(context)
    }

    public func createCodeSignTaskAction() -> any PlannedTaskAction {
        return CodeSignTaskAction()
    }

    public func createConcatenateTaskAction() -> any PlannedTaskAction {
        return ConcatenateTaskAction()
    }

    public func createGenerateEmbedInCodeAccessorTaskAction() -> any PlannedTaskAction {
        return GenerateEmbedInCodeAccessorTaskAction()
    }

    public func createCopyPlistTaskAction() -> any PlannedTaskAction {
        return CopyPlistTaskAction()
    }

    public func createCopyStringsFileTaskAction() -> any PlannedTaskAction {
        return CopyStringsFileTaskAction()
    }

    public func createCopyTiffTaskAction() -> any PlannedTaskAction {
        return CopyTiffTaskAction()
    }

    public func createDeferredExecutionTaskAction() -> any PlannedTaskAction {
        return DeferredExecutionTaskAction()
    }

    public func createBuildDirectoryTaskAction() -> any PlannedTaskAction {
        return CreateBuildDirectoryTaskAction()
    }

    public func createSwiftHeaderToolTaskAction() -> any PlannedTaskAction {
        return SwiftHeaderToolTaskAction()
    }

    public func createEmbedSwiftStdLibTaskAction() -> any PlannedTaskAction {
        return EmbedSwiftStdLibTaskAction()
    }

    public func createFileCopyTaskAction(_ context: FileCopyTaskActionContext) -> any PlannedTaskAction {
        return FileCopyTaskAction(context)
    }

    public func createGenericCachingTaskAction(enableCacheDebuggingRemarks: Bool, enableTaskSandboxEnforcement: Bool, sandboxDirectory: Path, extraSandboxSubdirectories: [Path], developerDirectory: Path, casOptions: CASOptions) -> any PlannedTaskAction {
        return GenericCachingTaskAction(enableCacheDebuggingRemarks: enableCacheDebuggingRemarks, enableTaskSandboxEnforcement: enableTaskSandboxEnforcement, sandboxDirectory: sandboxDirectory, extraSandboxSubdirectories: extraSandboxSubdirectories, developerDirectory: developerDirectory, casOptions: casOptions)
    }

    public func createInfoPlistProcessorTaskAction(_ contextPath: Path) -> any PlannedTaskAction {
        return InfoPlistProcessorTaskAction(contextPath)
    }

    public func createIngestCASFSRootTaskAction() -> any PlannedTaskAction {
        return IngestCASFSRootTaskAction()
    }

    public func createMergeInfoPlistTaskAction() -> any PlannedTaskAction {
        return MergeInfoPlistTaskAction()
    }

    public func createLinkAssetCatalogTaskAction() -> any PlannedTaskAction {
        return LinkAssetCatalogTaskAction()
    }

    public func createLSRegisterURLTaskAction() -> any PlannedTaskAction {
        return LSRegisterURLTaskAction()
    }

    public func createProcessProductEntitlementsTaskAction(mergedEntitlements: PropertyListItem, entitlementsVariant: EntitlementsVariant, allowEntitlementsModification: Bool, entitlementsDestination: EntitlementsDestination, destinationPlatformName: String, entitlementsFilePath: Path?, fs: any FSProxy) -> any PlannedTaskAction {
        return ProcessProductEntitlementsTaskAction(fs: fs, entitlements: mergedEntitlements, entitlementsVariant: entitlementsVariant, allowEntitlementsModification: allowEntitlementsModification, entitlementsDestination: entitlementsDestination, destinationPlatformName: destinationPlatformName, entitlementsFilePath: entitlementsFilePath)
    }

    public func createProcessProductProvisioningProfileTaskAction() -> any PlannedTaskAction {
        return ProcessProductProvisioningProfileTaskAction()
    }

    public func createRegisterExecutionPolicyExceptionTaskAction() -> any PlannedTaskAction {
        return RegisterExecutionPolicyExceptionTaskAction()
    }

    public func createValidateProductTaskAction() -> any PlannedTaskAction {
        return ValidateProductTaskAction()
    }

    public func createConstructStubExecutorInputFileListTaskAction() -> any PlannedTaskAction {
        return ConstructStubExecutorInputFileListTaskAction()
    }

    public func createODRAssetPackManifestTaskAction() -> any PlannedTaskAction {
        return ODRAssetPackManifestTaskAction()
    }

    public func createClangCompileTaskAction() -> any PlannedTaskAction {
        return ClangCompileTaskAction()
    }

    public func createClangScanTaskAction() -> any PlannedTaskAction {
        return ClangScanTaskAction()
    }

    public func createSwiftDriverTaskAction() -> any PlannedTaskAction {
        return SwiftDriverTaskAction()
    }

    func createSwiftCompilationRequirementTaskAction() -> any PlannedTaskAction {
        return SwiftDriverCompilationRequirementTaskAction()
    }

    func createSwiftExplicitModulesTaskAction() -> any PlannedTaskAction {
        return SwiftDriverExplicitModulesTaskAction()
    }

    func createSwiftCompilationTaskAction() -> any PlannedTaskAction {
        return SwiftCompilationTaskAction()
    }

    func createSwiftCompilationVerificationTaskAction() -> any PlannedTaskAction {
        return SwiftCompilationVerificationTaskAction()
    }

    public func createProcessXCFrameworkTask() -> any PlannedTaskAction {
        return ProcessXCFrameworkTaskAction()
    }

    func createValidateDevelopmentAssetsTaskAction() -> any PlannedTaskAction {
        return ValidateDevelopmentAssetsTaskAction()
    }

    func createSignatureCollectionTaskAction() -> any PlannedTaskAction {
        return SignatureCollectionTaskAction()
    }

    func createClangModuleVerifierInputGeneratorTaskAction() -> any PlannedTaskAction {
        return ClangModuleVerifierInputGeneratorTaskAction()
    }

    func createProcessSDKImportsTaskAction() -> any PlannedTaskAction {
        return ProcessSDKImportsTaskAction()
    }

    func createObjectLibraryAssemblerTaskAction() -> any PlannedTaskAction {
        return ObjectLibraryAssemblerTaskAction()
    }

    func createLinkerTaskAction(expandResponseFiles: Bool, responseFileFormat: ResponseFileFormat, extractArchiveInputs: Bool) -> any PlannedTaskAction {
        return LinkerTaskAction(expandResponseFiles: expandResponseFiles, responseFileFormat: responseFileFormat, extractArchiveInputs: extractArchiveInputs)
    }

    public func createTouchTaskAction() -> any PlannedTaskAction {
        return TouchTaskAction()
    }
}

extension CapturingTaskGenerationDelegate: CoreClientDelegate {
    func executeExternalTool(commandLine: [String], workingDirectory: Path?, environment: [String: String]) async throws -> ExternalToolResult {
        return .emptyResult
    }
}

private func lookUp<T: MacroDeclaration>(_ name: String, in namespace: MacroNamespace, as type: T.Type = T.self) throws -> T {
    guard let declaration = namespace.lookupMacroDeclaration(name) as? T else {
        throw StubError.error("\(name) isn't declared as a \(T.self)")
    }
    return declaration
}

/// A clang compile of one file, whose tasks are constructed with a mock table of settings.
private final class ClangCompileFixture {
    let clangSpec: CommandLineToolSpec
    let context: CommandBuildContext
    let delegate: CapturingTaskGenerationDelegate

    init() async throws {
        let core = try await TestingCore().getCore()

        clangSpec = try core.specRegistry.getSpec(ofType: ClangCompilerSpec.self)

        // Create the mock table.  We include all the defaults for the tool specification.
        var (table, namespace) = clangSpec.macroTableForBuildOptionDefaults(core)

        // We also add some other settings that are more contextual in nature.
        table.push(try lookUp("CURRENT_ARCH", in: namespace, as: StringMacroDeclaration.self), literal: "x86_64")
        table.push(try lookUp("arch", in: namespace, as: StringMacroDeclaration.self), literal: "x86_64")
        table.push(try lookUp("CURRENT_VARIANT", in: namespace, as: StringMacroDeclaration.self), literal: "normal")
        table.push(try lookUp("PRODUCT_NAME", in: namespace, as: StringMacroDeclaration.self), literal: "Product")
        table.push(try lookUp("TEMP_DIR", in: namespace, as: PathMacroDeclaration.self), literal: "/tmp")
        table.push(try lookUp("PROJECT_TEMP_DIR", in: namespace, as: PathMacroDeclaration.self), literal: "/tmp/ptmp")
        table.push(try lookUp("OBJECT_FILE_DIR", in: namespace, as: PathMacroDeclaration.self), literal: "/tmp/output/obj")
        table.push(try lookUp("BUILT_PRODUCTS_DIR", in: namespace, as: PathMacroDeclaration.self), literal: "/tmp/output/sym")
        table.push(try lookUp("GCC_PREFIX_HEADER", in: namespace, as: PathMacroDeclaration.self), literal: "/tmp/prefix.h")
        table.push(try lookUp("DERIVED_FILE_DIR", in: namespace, as: PathMacroDeclaration.self), literal: "/tmp/derived")
        table.push(try namespace.declareUserDefinedMacro("PER_ARCH_CFLAGS_i386"), namespace.parseLiteralStringList(["-DX86.32"]))
        table.push(try namespace.declareUserDefinedMacro("PER_ARCH_CFLAGS_x86_64"), namespace.parseLiteralStringList(["-DX86.64"]))
        table.push(try lookUp("PER_ARCH_CFLAGS", in: namespace, as: StringListMacroDeclaration.self), BuiltinMacros.namespace.parseStringList("$(PER_ARCH_CFLAGS_$(CURRENT_ARCH)"))
        table.push(try namespace.declareUserDefinedMacro("OTHER_CFLAGS_normal"), namespace.parseLiteralStringList(["-DFrom_OTHER_CFLAGS_normal"]))
        table.push(try namespace.declareUserDefinedMacro("OTHER_CFLAGS_profile"), namespace.parseLiteralStringList(["-DFrom_OTHER_CFLAGS_profile"]))
        table.push(try lookUp("PER_VARIANT_CFLAGS", in: namespace, as: StringListMacroDeclaration.self), BuiltinMacros.namespace.parseStringList("$(OTHER_CFLAGS_$(CURRENT_VARIANT)"))
        table.push(try lookUp("USE_HEADERMAP", in: namespace, as: BooleanMacroDeclaration.self), literal: true)
        table.push(try lookUp("HEADERMAP_USES_VFS", in: namespace, as: BooleanMacroDeclaration.self), literal: true)
        table.push(try lookUp("CLANG_ENABLE_MODULES", in: namespace, as: BooleanMacroDeclaration.self), literal: true)
        table.push(try namespace.declareStringListMacro("GLOBAL_CFLAGS"), literal: ["-DFrom_GLOBAL_CFLAGS"])
        table.push(try lookUp("GCC_GENERATE_PROFILING_CODE", in: namespace, as: BooleanMacroDeclaration.self), literal: true)
        table.push(try lookUp("GCC_PREPROCESSOR_DEFINITIONS_NOT_USED_IN_PRECOMPS", in: namespace, as: StringListMacroDeclaration.self), literal: ["defn1", "defn2"])
        table.push(try lookUp("GCC_OTHER_CFLAGS_NOT_USED_IN_PRECOMPS", in: namespace, as: StringListMacroDeclaration.self), literal: ["-DFrom_GCC_OTHER_CFLAGS_NOT_USED_IN_PRECOMPS"])

        // Override CLANG_DEBUG_MODULES, to be independent of recent changes to the Clang.xcspec.
        table.push(try lookUp("CLANG_DEBUG_MODULES", in: namespace, as: BooleanMacroDeclaration.self), literal: false)

        let producer = try MockCommandProducer(core: core, productTypeIdentifier: "com.apple.product-type.framework", platform: nil, fs: PseudoFS())
        delegate = try CapturingTaskGenerationDelegate(producer: producer, userPreferences: .defaultForTesting)
        let fileType = try core.specRegistry.getSpec("file", ofType: FileTypeSpec.self)
        context = CommandBuildContext(producer: producer, scope: MacroEvaluationScope(table: table), inputs: [FileToBuild(absolutePath: Path("/tmp/input.c"), fileType: fileType)], output: nil)
    }
}

func commandLineSpecBenchmarks() {
    // The iterations make heavy use of the constant flags cache, as a real build does, so they don't measure the
    // construction of an individual compile task from scratch.
    Benchmark.withFixture("CommandLineSpec.clangCompileTaskConstruction_X1000") {
        let fixture = try await ClangCompileFixture()
        await fixture.clangSpec.constructTasks(fixture.context, fixture.delegate)
        guard fixture.delegate.shellTasksCount.withLock({ $0 }) == 1 else {
            throw StubError.error("constructing the tasks of one compile didn't create exactly one task")
        }
        return fixture
    } _: { benchmark, fixture in
        for _ in 1...1000 {
            await fixture.clangSpec.constructTasks(fixture.context, fixture.delegate)
        }
    }
}
