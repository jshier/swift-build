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
import Foundation
import SWBBenchmarkSupport
import SWBCAS
import SWBUtil

/// A new CAS in a temporary directory, which also holds the files that benchmarks import and export.
private struct CASFixture {
    let temporaryDirectory: NamedTemporaryDirectory
    let casPlugin: ToolchainCASPlugin
    let cas: ToolchainCAS

    var path: Path { temporaryDirectory.path }
    var exportDirectory: Path { path.join("export") }

    init() async throws {
        temporaryDirectory = try NamedTemporaryDirectory()
        casPlugin = try ToolchainCASPlugin(dylib: try await Self.pluginPath())
        _ = casPlugin.getVersion()
        cas = try casPlugin.createCAS(path: temporaryDirectory.path.join("cas"), options: [:])
    }

    private static func pluginPath() async throws -> Path {
        if let pathString = getEnvironmentVariable("TOOLCHAIN_CAS_PLUGIN_PATH") {
            return Path(pathString)
        }
        return try await Xcode.getActiveDeveloperDirectoryPath().join("usr/lib/libToolchainCASPlugin.dylib")
    }

    /// Writes a 1 GiB file of random bytes at `A`, and returns its path.
    func writeLargeFile() throws -> Path {
        let path = path.join("A")
        try localFS.write(path, contents: randomBytes(1024 * 1024 * 1024))
        return path
    }

    /// Writes 100 directories of 100 small files each under `0`, and returns its path.
    func writeLargeDirectoryHierarchy() throws -> Path {
        let path1 = path.join("0")
        try localFS.createDirectory(path1)
        for i in 0..<100 {
            let path2 = path1.join("\(i)")
            try localFS.createDirectory(path2)
            for j in 0..<100 {
                let path3 = path2.join("\(j)")
                try localFS.write(path3, contents: "hello, world!")
            }
        }
        return path1
    }

    /// Removes the previous iteration's export, so that each iteration exports into a new directory.
    func removeExport() throws {
        try localFS.removeDirectory(exportDirectory)
    }

    func export(_ nodeID: ToolchainDataID) async throws {
        let node = try await CASFSNode.load(id: nodeID, cas: cas)
        try localFS.createDirectory(exportDirectory)
        try await node.export(into: exportDirectory, fs: localFS, cas: cas)
    }
}

/// Bytes from a fast pseudorandom generator, which, like truly random bytes, can't be deduplicated or compressed.
private func randomBytes(_ count: Int) -> ByteString {
    var state = UInt64.random(in: .min ... .max)
    var bytes = [UInt8](repeating: 0, count: count)
    bytes.withUnsafeMutableBytes { buffer in
        // SplitMix64, one word at a time.
        let words = buffer.bindMemory(to: UInt64.self)
        for index in words.indices {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            words[index] = z ^ (z >> 31)
        }
    }
    return ByteString(bytes)
}

func casFSNodeBenchmarks() {
    var configuration = Benchmark.Configuration.swiftBuild(maxIterations: 10)
    let hasPlugin = getEnvironmentVariable("TOOLCHAIN_CAS_PLUGIN_PATH") != nil || (try? ProcessInfo.processInfo.hostOperatingSystem()) == .macOS
    // Too expensive to run in CI.
    configuration.skip = !hasPlugin || getEnvironmentVariable("CI") != nil

    Benchmark.withFixture("CASFSNode.largeFileExportPerf", configuration: configuration) {
        let fixture = try await CASFixture()
        let nodeID = try await CASFSNode.import(path: fixture.writeLargeFile(), fs: localFS, cas: fixture.cas)
        return (fixture, nodeID)
    } _: { benchmark, setup in
        let (fixture, nodeID) = setup
        try fixture.removeExport()
        benchmark.startMeasurement()
        try await fixture.export(nodeID)
    }

    Benchmark.withFixture("CASFSNode.largeFileImportPerf", configuration: configuration) {
        let fixture = try await CASFixture()
        return (fixture, try fixture.writeLargeFile())
    } _: { benchmark, setup in
        let (fixture, path) = setup
        blackHole(try await CASFSNode.import(path: path, fs: localFS, cas: fixture.cas))
    }

    Benchmark.withFixture("CASFSNode.largeDirectoryHierarchyExportPerf", configuration: configuration) {
        let fixture = try await CASFixture()
        let nodeID = try await CASFSNode.import(path: fixture.writeLargeDirectoryHierarchy(), fs: localFS, cas: fixture.cas)
        return (fixture, nodeID)
    } _: { benchmark, setup in
        let (fixture, nodeID) = setup
        try fixture.removeExport()
        benchmark.startMeasurement()
        try await fixture.export(nodeID)
    }

    Benchmark.withFixture("CASFSNode.largeDirectoryHierarchyImportPerf", configuration: configuration) {
        let fixture = try await CASFixture()
        return (fixture, try fixture.writeLargeDirectoryHierarchy())
    } _: { benchmark, setup in
        let (fixture, path) = setup
        blackHole(try await CASFSNode.import(path: path, fs: localFS, cas: fixture.cas))
    }
}
