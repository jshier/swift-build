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

import struct Foundation.UUID

import Benchmark
import SWBBenchmarkSupport
import SWBCore
import SWBTestSupport
import SWBUtil
import SwiftBuild
import SwiftBuildTestSupport
import Testing

func xcFrameworkBenchmarks() {
    #if os(macOS)
        for useSwift in [true, false] {
            Benchmark.withFixture("XCFrameworkCreation.XCFrameworkCreationWithFrameworksPerf.\(useSwift)", configuration: .swiftBuild(maxIterations: 100)) {
                try await XCFrameworkCreationFixture { xcode, infoLookup, tmpDir in
                    let path1 = try await xcode.compileFramework(path: tmpDir.join("macos"), platform: .macOS, infoLookup: infoLookup, archs: ["arm64"], useSwift: useSwift)
                    let path2 = try await xcode.compileFramework(path: tmpDir.join("iphoneos"), platform: .iOS, infoLookup: infoLookup, archs: ["arm64", "arm64e"], useSwift: useSwift)
                    let path3 = try await xcode.compileFramework(path: tmpDir.join("iphonesimulator"), platform: .iOSSimulator, infoLookup: infoLookup, archs: ["arm64"], useSwift: useSwift)
                    return ["createXCFramework", "-framework", path1.str, "-framework", path2.str, "-framework", path3.str, "-output"]
                }
            } teardown: { fixture in
                await fixture.close()
            } _: { (benchmark: Benchmark, fixture: XCFrameworkCreationFixture) in
                try await fixture.createXCFramework(benchmark)
            }
        }

        for useSwift in [true, false] {
            Benchmark.withFixture("XCFrameworkCreation.XCFrameworkCreationWithDynamicLibrariesPerf.\(useSwift)", configuration: .swiftBuild(maxIterations: 100)) {
                try await XCFrameworkCreationFixture { xcode, infoLookup, tmpDir in
                    let path1 = try await xcode.compileDynamicLibrary(path: tmpDir.join("macos"), platform: .macOS, infoLookup: infoLookup, archs: ["arm64"], useSwift: useSwift)
                    let path2 = try await xcode.compileDynamicLibrary(path: tmpDir.join("iphoneos"), platform: .iOS, infoLookup: infoLookup, archs: ["arm64", "arm64e"], useSwift: useSwift)
                    let path3 = try await xcode.compileDynamicLibrary(path: tmpDir.join("iphonesimulator"), platform: .iOSSimulator, infoLookup: infoLookup, archs: ["arm64"], useSwift: useSwift)
                    return ["createXCFramework", "-library", path1.str, "-headers", path1.dirname.join("include").str, "-library", path2.str, "-headers", path2.dirname.join("include").str, "-library", path3.str, "-headers", path3.dirname.join("include").str, "-output"]
                }
            } teardown: { fixture in
                await fixture.close()
            } _: { (benchmark: Benchmark, fixture: XCFrameworkCreationFixture) in
                try await fixture.createXCFramework(benchmark)
            }
        }

        // Each iteration builds an app which links and embeds an XCFramework, from a clean build folder.
        Benchmark.withFixture("XCFrameworkCreation.buildPerformance_xcframework", configuration: .swiftBuild(maxIterations: 2)) {
            try await XCFrameworkBuildFixture()
        } teardown: { fixture in
            try await fixture.close()
        } _: { (benchmark: Benchmark, fixture: XCFrameworkBuildFixture) in
            try? localFS.removeDirectory(fixture.buildDirectory)
            benchmark.startMeasurement()
            let events = try await fixture.testSession.runBuildOperation(request: fixture.request, delegate: TestBuildOperationDelegate())
            benchmark.stopMeasurement()
            try events.requireNoErrors()
        }
    #endif
}

/// The libraries for three platforms, and a build service console that creates XCFrameworks from them.
private final class XCFrameworkCreationFixture {
    let temporaryDirectory: NamedTemporaryDirectory
    let commandLine: [String]
    let service: SWBBuildService
    let console: SWBBuildServiceConsole

    /// Makes the libraries with `compile`, which returns the command line that creates an XCFramework from them, without the output path.
    init(_ compile: (InstalledXcode, any PlatformInfoLookup, Path) async throws -> [String]) async throws {
        let xcode = try await InstalledXcode.currentlySelected()
        let infoLookup = try await TestingCore().getCore()
        temporaryDirectory = try NamedTemporaryDirectory()
        commandLine = try await compile(xcode, infoLookup, temporaryDirectory.path)
        service = try await SWBBuildService()
        console = SWBBuildServiceConsole(service: service)
        do {
            let (result, passed) = await console.sendCommand(commandLine + [temporaryDirectory.path.join("check.xcframework").str])
            guard passed else {
                throw StubError.error("Creating an XCFramework failed: \(result.output)")
            }
        } catch {
            await close()
            throw error
        }
    }

    func createXCFramework(_ benchmark: Benchmark) async throws {
        let commandLine = commandLine + [temporaryDirectory.path.join("sample-\(Foundation.UUID().description).xcframework").str]
        benchmark.startMeasurement()
        blackHole(await console.sendCommand(commandLine))
    }

    func close() async {
        try? await console.close()
        await service.close()
    }
}

/// An app which links and embeds an XCFramework made from frameworks for three platforms.
private final class XCFrameworkBuildFixture {
    let testSession: TestSWBSession
    let tester: CoreQualificationTester
    let request: SWBBuildRequest
    let buildDirectory: Path

    init() async throws {
        let fs = localFS
        let xcode = try await InstalledXcode.currentlySelected()
        let infoLookup = try await TestingCore().getCore()
        let temporaryDirectory = try NamedTemporaryDirectory()
        let tmpDir = temporaryDirectory.path
        let testSession = try await TestSWBSession(temporaryDirectory: temporaryDirectory)
        self.testSession = testSession
        do {
            let path1 = try await xcode.compileFramework(path: tmpDir.join("macos"), platform: .macOS, infoLookup: infoLookup, archs: ["arm64"], useSwift: true)
            let path2 = try await xcode.compileFramework(path: tmpDir.join("iphoneos"), platform: .iOS, infoLookup: infoLookup, archs: ["arm64", "arm64e"], useSwift: true)
            let path3 = try await xcode.compileFramework(path: tmpDir.join("iphonesimulator"), platform: .iOSSimulator, infoLookup: infoLookup, archs: ["arm64"], useSwift: true)

            let outputPath = tmpDir.join("sample.xcframework")
            let commandLine = ["createXCFramework", "-framework", path1.str, "-framework", path2.str, "-framework", path3.str, "-output", outputPath.str]

            let (result, message) = await testSession.service.createXCFramework(commandLine, currentWorkingDirectory: tmpDir.str, developerPath: nil)
            guard result else {
                throw StubError.error("Unable to build the XCFramework: \(message)")
            }

            let testTarget = TestStandardTarget(
                "App",
                type: .application,
                buildConfigurations: [
                    TestBuildConfiguration("Debug")
                ],
                buildPhases: [
                    TestSourcesBuildPhase(["main.swift"]),
                    TestFrameworksBuildPhase(["sample.xcframework"]),
                ],
                dependencies: []
            )

            let testProject = TestProject(
                "aProject",
                groupTree: TestGroup(
                    "SomeFiles",
                    children: [
                        TestFile("main.swift"),
                        TestFile("sample.xcframework"),
                        TestFile("Info.plist"),
                    ]),
                buildConfigurations: [
                    TestBuildConfiguration(
                        "Debug",
                        buildSettings: [
                            "ALWAYS_SEARCH_USER_PATHS": "NO",
                            "GENERATE_INFOPLIST_FILE": "YES",
                            "PRODUCT_NAME": "$(TARGET_NAME)",
                            "CODE_SIGN_IDENTITY": "-",
                            "ARCHS": "arm64",
                            "SWIFT_VERSION": "5",
                        ])
                ],
                targets: [testTarget])

            let testWorkspace = TestWorkspace(
                "aWorkspace",
                sourceRoot: tmpDir.join("Test"),
                projects: [testProject])
            let SRCROOT = testWorkspace.sourceRoot.join("aProject")
            buildDirectory = SRCROOT.join("build")

            tester = try await CoreQualificationTester(testWorkspace, testSession, fs: fs)

            try fs.createDirectory(SRCROOT, recursive: true)

            // Copy the xcframework into place so it can be found.
            try fs.copy(outputPath, to: SRCROOT.join(outputPath.basename))

            try fs.write(SRCROOT.join("main.swift"), contents: "import Foundation\npublic func f() {}\n")

            var request = SWBBuildRequest()
            request.useParallelTargets = true
            request.parameters = SWBBuildParameters()
            request.parameters.action = "build"
            request.parameters.configurationName = "Debug"
            request.add(target: SWBConfiguredTarget(guid: testTarget.guid, parameters: nil))
            self.request = request
        } catch {
            try? await testSession.close()
            throw error
        }
    }

    func close() async throws {
        try await tester.invalidate()
        try await testSession.close()
    }
}
