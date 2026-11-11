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

import SWBCore
import SWBUtil
import SWBTaskConstruction
import SWBMacro

final class AppIntentsMetadataTaskProducer: PhasedTaskProducer, TaskProducer {

    init(_ context: TargetTaskProducerContext, phaseStartNodes: [any PlannedNode], phaseEndNode: any PlannedNode) {
        super.init(context, phaseStartNodes: phaseStartNodes, phaseEndNode: phaseEndNode)
    }

    override var defaultTaskOrderingOptions: TaskOrderingOptions {
        return .unsignedProductRequirement
    }

    private func filterBuildFiles(_ buildFiles: [BuildFile]?, identifiers: [String], buildFilesProcessingContext: BuildFilesProcessingContext) -> [FileToBuild] {
        guard let buildFiles else {
            return []
        }

        let fileTypes = identifiers.compactMap { identifier in
            context.lookupFileType(identifier: identifier)
        }

        return fileTypes.flatMap { fileType in
            buildFiles.compactMap { buildFile in
                guard let resolvedBuildFileInfo = try? self.context.resolveBuildFileReference(buildFile),
                      !buildFilesProcessingContext.isExcluded(resolvedBuildFileInfo.absolutePath, platformFilters: buildFile.platformFilters, buildConfigurationFilters: buildFile.buildConfigurationFilters),
                      resolvedBuildFileInfo.fileType.conformsTo(fileType) else {
                    return nil
                }

                return FileToBuild(absolutePath: resolvedBuildFileInfo.absolutePath, fileType: fileType)
            }
        }
    }

    func generateTasks() async -> [any PlannedTask] {
        let tasks: [any PlannedTask] = []
        guard let compilerSpec = self.context.appShortcutStringsMetadataCompilerSpec else {
            return []
        }
        guard !context.settings.globalScope.evaluate(BuiltinMacros.LM_SKIP_METADATA_EXTRACTION) else {
            return []
        }
        guard let configuredTarget = self.targetContext.configuredTarget, let buildPhaseTarget = configuredTarget.target as? BuildPhaseTarget else {
            return []
        }

        context.addDeferredProducer {
            let scope = self.context.settings.globalScope
            var deferredTasks: [any PlannedTask] = []
            let buildFilesProcessingContext = BuildFilesProcessingContext(self.context.settings.globalScope)
            let swiftSources: [FileToBuild] = self.filterBuildFiles(buildPhaseTarget.sourcesBuildPhase?.buildFiles, identifiers: ["sourcecode.swift"], buildFilesProcessingContext: buildFilesProcessingContext)
            let perArchConstMetadataFiles = self.context.generatedSwiftConstMetadataFiles()

            var metadataDependencyList: Set<Path> = []
            var staticLibraryDependencyList: Set<Path> = []
            if let configuredTarget = self.targetContext.configuredTarget {
                let globalProductPlan = self.targetContext.globalProductPlan
                // Each target depending on a dependency computes the same paths for it. Whether it's a bundle depends on the spec domain of this target.
                let memoizationKey = "AppIntentsMetadataPaths:\(self.context.domain)"
                let dependencies = transitiveClosure([configuredTarget], successors: globalProductPlan.dependencies(of:))
                for dependency in dependencies.0 {
                    let paths = globalProductPlan.memoizedValue(for: dependency, key: memoizationKey) { () -> (bundle: Path?, staticLibrary: Path?) in
                        var bundleMetadataPath: Path?
                        if let standardTarget = dependency.target as? StandardTarget,
                           let bundleProductType = self.context.getSpec(standardTarget.productTypeIdentifier),
                           bundleProductType.conformsTo(identifier: "com.apple.product-type.bundle") {
                            let targetScope = globalProductPlan.getTargetSettings(dependency).globalScope
                            bundleMetadataPath = targetScope.evaluate(BuiltinMacros.TARGET_BUILD_DIR)
                                .join(targetScope.evaluate(BuiltinMacros.UNLOCALIZED_RESOURCES_FOLDER_PATH))
                                .join("Metadata.appintents/extract.actionsdata")
                        }
                        var staticLibraryMetadataPath: Path?
                        let targetScope = globalProductPlan.getTargetSettings(dependency).globalScope
                        let machOType = targetScope.evaluate(BuiltinMacros.MACH_O_TYPE)
                        if  machOType == "staticlib" || machOType == "mh_object" {
                            staticLibraryMetadataPath = targetScope.evaluate(BuiltinMacros.TARGET_BUILD_DIR)
                                .join(targetScope.evaluate(BuiltinMacros.PRODUCT_MODULE_NAME) + ".appintents")
                                .join("Metadata.appintents/extract.actionsdata")
                        }
                        return (bundleMetadataPath, staticLibraryMetadataPath)
                    }
                    if let bundle = paths.bundle {
                        metadataDependencyList.insert(bundle)
                    }
                    if let staticLibrary = paths.staticLibrary {
                        staticLibraryDependencyList.insert(staticLibrary)
                    }
                }
            }

            // In expectation, these files will not differ between architectures and AppIntentsMetadataProcessor only runs once, on the final binary
            // To attempt to make this deterministic, let's pick the list corresponding to the first arch alphabetically.
            let constMetadataFiles: [Path]
            if let firstArch = perArchConstMetadataFiles.keys.sorted().first {
                constMetadataFiles = perArchConstMetadataFiles[firstArch]!
            } else {
                constMetadataFiles = []
            }

            let constMetadataFilesToBuild = constMetadataFiles.map { absolutePath -> FileToBuild in
                let fileType = self.context.workspaceContext.core.specRegistry.getSpec("file") as! FileTypeSpec
                return FileToBuild(absolutePath: absolutePath, fileType: fileType)
            }

            await self.appendGeneratedTasks(&deferredTasks) { delegate in
                let metadataDependencyPath = scope.evaluate(BuiltinMacros.LM_AUX_INTENTS_METADATA_FILES_LIST_PATH)
                if !metadataDependencyPath.isEmpty {
                    let fileListContents = OutputByteStream()
                    for metadataPath in metadataDependencyList.sorted() {
                        fileListContents <<< metadataPath.str <<< "\n"
                    }

                    let path = metadataDependencyPath
                    self.context.writeFileSpec.constructFileTasks(CommandBuildContext(producer: self.context, scope: scope, inputs: [], output: path), delegate, contents: fileListContents.bytes, permissions: nil, preparesForIndexing: true, additionalTaskOrderingOptions: [.immediate, .ignorePhaseOrdering])
                }
            }

            await self.appendGeneratedTasks(&deferredTasks) { delegate in
                let metadataDependencyPath = scope.evaluate(BuiltinMacros.LM_AUX_INTENTS_STATIC_METADATA_FILES_LIST_PATH)
                if !metadataDependencyPath.isEmpty {
                    let fileListContents = OutputByteStream()
                    for metadataPath in staticLibraryDependencyList.sorted() {
                        fileListContents <<< metadataPath.str <<< "\n"
                    }

                    self.context.writeFileSpec
                        .constructFileTasks(
                            CommandBuildContext(producer: self.context, scope: scope, inputs: [], output: metadataDependencyPath),
                            delegate,
                            contents: fileListContents.bytes,
                            permissions: nil,
                            preparesForIndexing: true,
                            additionalTaskOrderingOptions: [.immediate, .ignorePhaseOrdering]
                        )
                }

            }
            let appShortcutStringsSources: [FileToBuild] = self.filterBuildFiles(buildPhaseTarget.resourcesBuildPhase?.buildFiles, identifiers: ["text.plist.strings", "text.json.xcstrings"], buildFilesProcessingContext: buildFilesProcessingContext).filter { ["AppShortcuts.strings", "AppShortcuts.xcstrings"].contains($0.absolutePath.basename) }

            let cbc = CommandBuildContext(producer: self.context, scope: scope, inputs: swiftSources + constMetadataFilesToBuild + appShortcutStringsSources, resourcesDir: buildFilesProcessingContext.resourcesDir)


            await self.appendGeneratedTasks(&deferredTasks) { delegate in
                let shouldConstructAppIntentsMetadataTask = self.context.appIntentsMetadataCompilerSpec.shouldConstructAppIntentsMetadataTask(cbc)
                let isInstallLoc = scope.evaluate(BuiltinMacros.BUILD_COMPONENTS).contains("installLoc")
                await self.context.appIntentsMetadataCompilerSpec.constructTasks(cbc, delegate)

                if appShortcutStringsSources.count == 1 {
                    let appShortcutsMetadataCbc = CommandBuildContext(producer: self.context, scope: scope, inputs: appShortcutStringsSources, resourcesDir: buildFilesProcessingContext.resourcesDir)
                    await compilerSpec.constructTasks(appShortcutsMetadataCbc, delegate)
                }

                // Only construct SSU task by default for public SDK clients. Internal default behavior should skip SSU task construction.
                let isSSUEnabled = scope.evaluate(BuiltinMacros.APP_SHORTCUTS_ENABLE_FLEXIBLE_MATCHING)
                if isSSUEnabled &&
                    self.context.settings.platform?.familyName == "iOS" &&
                    self.context.productType?.hasInfoPlist == true &&
                    ((!scope.effectiveInputInfoPlistPath().isEmpty && shouldConstructAppIntentsMetadataTask) || isInstallLoc) {
                    var infoPlistSources: [FileToBuild]
                    if isInstallLoc {
                        infoPlistSources = self.filterBuildFiles(buildPhaseTarget.resourcesBuildPhase?.buildFiles, identifiers: ["text.plist.strings", "text.json.xcstrings"], buildFilesProcessingContext: buildFilesProcessingContext).filter { $0.absolutePath.basename.hasSuffix("InfoPlist.strings") || $0.absolutePath.basename.hasSuffix("InfoPlist.xcstrings") }
                        // The installLoc builds should include an AppShortcuts strings/xcstrings file to run SSU tasks
                        guard appShortcutStringsSources.count == 1 else {
                            return
                        }
                    } else {
                        infoPlistSources = [FileToBuild(absolutePath: scope.evaluate(BuiltinMacros.TARGET_BUILD_DIR).join(scope.evaluate(BuiltinMacros.INFOPLIST_PATH)), inferringTypeUsing: self.context)]
                    }
                    let yamlGenerationInputs: [FileToBuild] = infoPlistSources + appShortcutStringsSources
                    let appIntentsSsuTrainingCbc = CommandBuildContext(producer: self.context, scope: scope, inputs: yamlGenerationInputs, resourcesDir: buildFilesProcessingContext.resourcesDir)
                    await self.context.appIntentsSsuTrainingCompilerSpec.constructTasks(appIntentsSsuTrainingCbc, delegate)
                }
            }
            return deferredTasks
        }

        return tasks
    }
}

extension TaskProducerContext {
    var appIntentsMetadataCompilerSpec: AppIntentsMetadataCompilerSpec {
        return workspaceContext.core.specRegistry.getSpec("com.apple.compilers.appintentsmetadata", domain: domain) as! AppIntentsMetadataCompilerSpec
    }

    var appIntentsSsuTrainingCompilerSpec: AppIntentsSSUTrainingCompilerSpec {
        return workspaceContext.core.specRegistry.getSpec("com.apple.compilers.appintents-ssu-training", domain: domain) as! AppIntentsSSUTrainingCompilerSpec
    }
}
