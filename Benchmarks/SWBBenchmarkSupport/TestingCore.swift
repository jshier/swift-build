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

package import SWBCore
package import SWBTestSupport

/// Provides the core of the default toolchain, and its tools, as `CoreBasedTests` does for tests.
package struct TestingCore: CoreBasedTests, Sendable {
    package init() {}
}

/// Keeps a workspace's settings cached from creation until `end()`, as a build does while it's planned, across a
/// benchmark's separate setup, iterations and teardown.
package final class KeptAliveSettings: Sendable {
    private let release: AsyncStream<Void>.Continuation
    private let scope: Task<Void, Never>

    package init(_ workspaceContext: WorkspaceContext) async {
        let (released, release) = AsyncStream<Void>.makeStream()
        let (started, start) = AsyncStream<Void>.makeStream()
        self.release = release
        scope = Task {
            await BuildRequestContext(workspaceContext: workspaceContext).keepAliveSettingsCache {
                start.finish()
                for await _ in released {}
            }
        }
        for await _ in started {}
    }

    package func end() async {
        release.finish()
        await scope.value
    }
}
