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

package import Benchmark

/// Holds a benchmark's fixture between its setup and teardown.
private final class FixtureStorage<Fixture>: @unchecked Sendable {
    var fixture: Fixture?
}

private struct MissingFixture: Error {}

extension Benchmark {
    /// Registers a benchmark whose fixture is made before its iterations and released after them, so that making it
    /// isn't measured, and later benchmarks in the same process don't keep it in memory.
    @discardableResult
    package static func withFixture<Fixture>(
        _ name: String,
        configuration: Benchmark.Configuration = Benchmark.defaultConfiguration,
        setup: @escaping () async throws -> Fixture,
        teardown: @escaping (Fixture) async throws -> Void = { _ in },
        _ body: @escaping (Benchmark, Fixture) async throws -> Void
    ) -> Benchmark? {
        let storage = FixtureStorage<Fixture>()
        return Benchmark(name, configuration: configuration) { (benchmark: Benchmark) async throws in
            guard let fixture = storage.fixture else { throw MissingFixture() }
            try await body(benchmark, fixture)
        } setup: {
            storage.fixture = try await setup()
        } teardown: {
            if let fixture = storage.fixture {
                try await teardown(fixture)
            }
            storage.fixture = nil
        }
    }
}
